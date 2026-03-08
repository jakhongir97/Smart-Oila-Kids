import Foundation
import UserNotifications

actor MediaIntegrityNotifier {
    static let shared = MediaIntegrityNotifier()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func recordPermissionRevoked(
        dsn: String? = nil,
        mediaType: MediaTelemetryType
    ) async {
        guard let normalizedDSN = normalizedDSN(dsn ?? currentDSN()) else { return }
        let now = Date()
        let fingerprint = [
            MediaTelemetryEvent.permissionRevoked.rawValue,
            normalizedDSN.lowercased(),
            mediaType.rawValue
        ].joined(separator: "|")
        guard shouldRecord(fingerprint: fingerprint, now: now) else { return }

        let title = L10n.tr("notifications.media.permission_revoked_title", localizedMediaType(for: mediaType))
        let body = permissionRevokedBody(for: mediaType)

        await MediaTelemetryNotifier.shared.record(
            .permissionRevoked,
            dsn: normalizedDSN,
            mediaType: mediaType,
            reason: body
        )
        scheduleLocalNotification(
            title: title,
            body: body,
            event: .permissionRevoked,
            dsn: normalizedDSN
        )
    }

    func recordForegroundInterrupted(
        dsn: String? = nil,
        mediaType: MediaTelemetryType,
        recordingID: String? = nil
    ) async {
        guard let normalizedDSN = normalizedDSN(dsn ?? currentDSN()) else { return }
        let now = Date()
        let fingerprint = [
            MediaTelemetryEvent.foregroundInterrupted.rawValue,
            normalizedDSN.lowercased(),
            mediaType.rawValue,
            normalizedIdentifier(recordingID) ?? ""
        ].joined(separator: "|")
        guard shouldRecord(fingerprint: fingerprint, now: now) else { return }

        let title = L10n.tr("notifications.media.foreground_interrupted_title", localizedMediaType(for: mediaType))
        let body = foregroundInterruptedBody(for: mediaType)

        await MediaTelemetryNotifier.shared.record(
            .foregroundInterrupted,
            dsn: normalizedDSN,
            mediaType: mediaType,
            recordingID: recordingID,
            reason: body
        )
        scheduleLocalNotification(
            title: title,
            body: body,
            event: .foregroundInterrupted,
            dsn: normalizedDSN
        )
    }

    private let userDefaults: UserDefaults
    private let cooldown: TimeInterval = 600
}

private extension MediaIntegrityNotifier {
    enum Keys {
        static let currentDSN = "DSN"
        static let lastSentAtPrefix = "MEDIA_INTEGRITY_LAST_SENT_"
    }

    func scheduleLocalNotification(
        title: String,
        body: String,
        event: MediaTelemetryEvent,
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
            identifier: "media.integrity.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func localizedMediaType(for type: MediaTelemetryType) -> String {
        switch type {
        case .environment, .audioStream:
            return L10n.tr("notifications.media.media_type_microphone")
        case .camera, .cameraStream, .frontCameraStream:
            return L10n.tr("notifications.media.media_type_camera")
        case .display:
            return L10n.tr("notifications.media.media_type_screen")
        }
    }

    func permissionRevokedBody(for type: MediaTelemetryType) -> String {
        switch type {
        case .environment, .audioStream:
            return L10n.tr("notifications.media.permission_revoked_microphone_body")
        case .camera, .cameraStream, .frontCameraStream:
            return L10n.tr("notifications.media.permission_revoked_camera_body")
        case .display:
            return L10n.tr("notifications.media.permission_revoked_screen_body")
        }
    }

    func foregroundInterruptedBody(for type: MediaTelemetryType) -> String {
        switch type {
        case .display:
            return L10n.tr("notifications.media.foreground_interrupted_screen_body")
        default:
            return L10n.tr("notifications.media.foreground_interrupted_body")
        }
    }

    func currentDSN() -> String? {
        normalizedDSN(userDefaults.string(forKey: Keys.currentDSN))
    }

    func normalizedDSN(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
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
}

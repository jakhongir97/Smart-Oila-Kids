import Foundation

extension Notification.Name {
    static let pushShouldRefreshLockState = Notification.Name("smartoila.push.refreshLockState")
    static let pushShouldRefreshTasks = Notification.Name("smartoila.push.refreshTasks")
    static let pushShouldOpenTasks = Notification.Name("smartoila.push.openTasks")
    static let pushShouldRefreshChat = Notification.Name("smartoila.push.refreshChat")
    static let pushShouldOpenChat = Notification.Name("smartoila.push.openChat")
    static let pushShouldStartAudioStream = Notification.Name("smartoila.push.startAudioStream")
    static let pushShouldStopAudioStream = Notification.Name("smartoila.push.stopAudioStream")
    static let pushShouldRefreshDashboard = Notification.Name("smartoila.push.refreshDashboard")
    static let pushInboxDidChange = Notification.Name("smartoila.push.inboxDidChange")
}

enum PushUserInfoKeys {
    static let dsn = "dsn"
    /// Structured `stream.start` fields, forwarded from the FCM data payload to
    /// `DeviceAudioStreamManager` so it can honour the server-owned lease contract (D-073).
    /// All arrive as strings from FCM; the manager parses them.
    static let streamMode = "streamMode"                     // "audio" | "video"
    static let streamCameraType = "streamCameraType"         // "Front" | "Back" | absent
    static let streamMaxDurationSeconds = "streamMaxDurationSeconds"  // e.g. "120"
    static let streamExpiresAt = "streamExpiresAt"           // epoch milliseconds
}

/// Identifiers for the notifications this app schedules itself.
///
/// They exist so the delivery callbacks can tell "the server sent us a command" from "we posted
/// this banner a moment ago". `willPresent` and `didReceive` route every arriving notification
/// through `PushCommandRouter`, and two of the local ones carry a `dsn` + `event` userInfo — the
/// exact shape the router parses — so the app was re-ingesting its own output as if it were a
/// fresh server command: duplicated inbox rows and a badge counting each event twice.
enum LocalNotificationID {
    /// The live-session presence banner. A fixed id: re-posting REPLACES it rather than stacking.
    static let livePresence = "oila.live-stream.presence"
    /// Prefixes; the schedulers append a UUID so each event gets its own banner.
    static let integrityPrefix = "device-control.integrity."
    static let recoveryPrefix = "device-control.recovery."

    /// True when this app scheduled the notification, so the caller must not treat it as an
    /// inbound command.
    static func isLocallyScheduled(_ identifier: String) -> Bool {
        identifier == livePresence
            || identifier.hasPrefix(integrityPrefix)
            || identifier.hasPrefix(recoveryPrefix)
    }
}

enum PushDeepLinkDestination: String, Codable {
    case chat
    case tasks
}

struct PushInboxItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let event: String
    let dsn: String?
    let receivedAt: Date
    var isRead: Bool
    let fingerprint: String
}

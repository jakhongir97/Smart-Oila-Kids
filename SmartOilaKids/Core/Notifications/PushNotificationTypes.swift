import Foundation

extension Notification.Name {
    static let pushShouldRefreshLockState = Notification.Name("smartoila.push.refreshLockState")
    static let pushShouldRefreshTasks = Notification.Name("smartoila.push.refreshTasks")
    static let pushShouldOpenTasks = Notification.Name("smartoila.push.openTasks")
    static let pushShouldRefreshChat = Notification.Name("smartoila.push.refreshChat")
    static let pushShouldOpenChat = Notification.Name("smartoila.push.openChat")
    static let pushShouldStartAudioStream = Notification.Name("smartoila.push.startAudioStream")
    static let pushShouldStopAudioStream = Notification.Name("smartoila.push.stopAudioStream")
    /// The backend's `status.report` command: post a fresh `/device/status` snapshot NOW.
    ///
    /// This replaced `pushShouldRefreshDashboard`, which was posted for any push whose event, TITLE
    /// or BODY contained "log"/"usage"/"geo"/"location"/"stat"/"system" — i.e. it fired on ordinary
    /// parent messages — and which no object in the app ever observed. This name is posted only from
    /// the structured event, the same rule the audio wake follows, and it has a real consumer
    /// (`OilaTelemetryService`).
    static let pushShouldReportStatus = Notification.Name("smartoila.push.reportStatus")
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
    /// "Your parent sent a message". Also a fixed id, for the same reason and the same way the
    /// Android child app does it (one notification id, re-posted): a child who has been away should
    /// come back to one banner, not one per message.
    static let chatMessage = "oila.chat.message"
    /// Prefixes; the schedulers append a UUID so each event gets its own banner.
    static let integrityPrefix = "device-control.integrity."
    static let recoveryPrefix = "device-control.recovery."

    /// True when this app scheduled the notification, so the caller must not treat it as an
    /// inbound command.
    ///
    /// `chatMessage` is included: it is app-authored, so routing it back through the command router
    /// would re-run the chat refresh and write our own text into the push inbox. Its TAP still has
    /// to open the chat, which `SmartOilaKidsAppDelegate.didReceive` handles explicitly.
    static func isLocallyScheduled(_ identifier: String) -> Bool {
        identifier == livePresence
            || identifier == chatMessage
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

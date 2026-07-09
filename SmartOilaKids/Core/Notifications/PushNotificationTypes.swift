import Foundation

extension Notification.Name {
    static let pushShouldRefreshLockState = Notification.Name("smartoila.push.refreshLockState")
    static let pushShouldRefreshTasks = Notification.Name("smartoila.push.refreshTasks")
    static let pushShouldOpenTasks = Notification.Name("smartoila.push.openTasks")
    static let pushShouldRefreshChat = Notification.Name("smartoila.push.refreshChat")
    static let pushShouldOpenChat = Notification.Name("smartoila.push.openChat")
    static let pushShouldRefreshDashboard = Notification.Name("smartoila.push.refreshDashboard")
    static let pushShouldStartRecording = Notification.Name("smartoila.push.startRecording")
    static let pushInboxDidChange = Notification.Name("smartoila.push.inboxDidChange")
}

enum PushUserInfoKeys {
    static let dsn = "dsn"
    /// Carries a parsed `PushRecordingCommand` on `.pushShouldStartRecording`.
    static let recordingCommand = "recordingCommand"
}

// MARK: - Recording trigger (oila360 TriggerRecordingDto → push)

enum PushRecordingMediaType: String, Equatable {
    case audio
    case video
}

enum PushRecordingCameraType: String, Equatable {
    case front
    case back
}

/// A parent-triggered recording command extracted from a push payload
/// (TriggerRecordingDto: type Audio|Video, durationSeconds 1-300, cameraType Front|Back).
/// The recording id is mandatory — without it the finished clip cannot be uploaded to
/// `PUT /device/recordings/{id}/complete`.
struct PushRecordingCommand: Equatable {
    static let durationRange = 1 ... 300
    static let defaultDurationSeconds = 10

    let recordingID: String
    let type: PushRecordingMediaType
    let durationSeconds: Int
    let cameraType: PushRecordingCameraType?

    /// Clamps an arbitrary pushed duration into the contract's 1–300s window.
    static func clampedDuration(_ raw: Int?) -> Int {
        guard let raw else { return defaultDurationSeconds }
        return min(max(raw, durationRange.lowerBound), durationRange.upperBound)
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

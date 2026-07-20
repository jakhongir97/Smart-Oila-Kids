import Foundation

extension Notification.Name {
    static let pushShouldRefreshLockState = Notification.Name("smartoila.push.refreshLockState")
    static let pushShouldRefreshTasks = Notification.Name("smartoila.push.refreshTasks")
    static let pushShouldOpenTasks = Notification.Name("smartoila.push.openTasks")
    static let pushShouldRefreshChat = Notification.Name("smartoila.push.refreshChat")
    static let pushShouldOpenChat = Notification.Name("smartoila.push.openChat")
    static let pushShouldRefreshDashboard = Notification.Name("smartoila.push.refreshDashboard")
    static let pushInboxDidChange = Notification.Name("smartoila.push.inboxDidChange")
}

enum PushUserInfoKeys {
    static let dsn = "dsn"
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

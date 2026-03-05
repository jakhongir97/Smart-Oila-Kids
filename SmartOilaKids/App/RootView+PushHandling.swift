import Foundation

extension RootView {
    func shouldHandlePush(notification: Notification, currentDSN: String?) -> Bool {
        guard let currentDSN = currentDSN?.trimmedNonEmpty else { return false }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }
}

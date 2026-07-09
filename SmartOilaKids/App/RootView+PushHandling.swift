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

/// Decides what a parent "lock" push refreshes. The oila360 lock state (GET /device/lock/state,
/// which drives the lock overlay) must ALWAYS refresh immediately — it otherwise waits for the
/// 30s poll. Only the legacy Screen Time DeviceLockCoordinator stays behind its feature flag.
enum LockPushRefreshPolicy {
    struct Actions: Equatable {
        let refreshOilaLockState: Bool
        let refreshLegacyLockCoordinator: Bool
    }

    static func actions(
        pushMatchesSession: Bool,
        screenTimeFeaturesEnabled: Bool,
        shouldRunLocalChildServices: Bool
    ) -> Actions {
        guard pushMatchesSession else {
            return Actions(refreshOilaLockState: false, refreshLegacyLockCoordinator: false)
        }
        return Actions(
            refreshOilaLockState: true,
            refreshLegacyLockCoordinator: screenTimeFeaturesEnabled && shouldRunLocalChildServices
        )
    }
}

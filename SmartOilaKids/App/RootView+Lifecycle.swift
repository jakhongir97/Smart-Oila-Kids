import SwiftUI

extension RootView {
    func handleAppear() {
        lastSessionDSN = sessionStore.dsn?.trimmedNonEmpty
        syncGeoService(with: sessionStore.dsn)
        syncLockService(with: sessionStore.dsn)
        Task {
            await PushTokenSyncCoordinator.shared.updateDSN(sessionStore.dsn)
            await PushInboxStore.shared.reconcileAppBadge()
        }
    }

    func handleDSNChange(_ newValue: String?) {
        let normalizedNewDSN = newValue?.trimmedNonEmpty
        let previousDSN = lastSessionDSN?.trimmedNonEmpty
        lastSessionDSN = normalizedNewDSN

        syncGeoService(with: newValue)
        syncLockService(with: newValue)

        Task {
            await PushTokenSyncCoordinator.shared.updateDSN(normalizedNewDSN)

            if let previousDSN,
               !dsnEquals(previousDSN, normalizedNewDSN) {
                await PushDeepLinkStore.shared.clear(matching: previousDSN)
                await PushInboxStore.shared.clear(dsn: previousDSN)
            }

            if normalizedNewDSN == nil {
                await PushDeepLinkStore.shared.clearAll()
                await PushInboxStore.shared.clearAll()
            } else {
                await PushInboxStore.shared.reconcileAppBadge()
            }
        }
    }

    func handleScenePhaseChange(_ newValue: ScenePhase) {
        guard newValue == .active else { return }
        Task {
            await lockCoordinator.refreshNow()
        }
    }

    func handleLockRefreshNotification(_ notification: Notification) {
        guard shouldHandlePush(notification: notification, currentDSN: sessionStore.dsn) else { return }
        Task {
            await lockCoordinator.refreshNow()
        }
    }
}

private extension RootView {
    func syncGeoService(with dsn: String?) {
        guard let dsn, !dsn.isEmpty else {
            geoBackgroundService.stop()
            return
        }
        geoBackgroundService.start(dsn: dsn)
    }

    func syncLockService(with dsn: String?) {
        lockCoordinator.start(dsn: dsn)
    }

    func dsnEquals(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs = rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

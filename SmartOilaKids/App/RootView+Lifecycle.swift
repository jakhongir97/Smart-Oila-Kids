import SwiftUI
import UIKit

extension RootView {
    func handleAppear() {
        let isInitialAppear = !didHandleInitialAppear
        didHandleInitialAppear = true
        let shouldArmLaunchRecovery = isInitialAppear && shouldArmLaunchRecoveryCheck(referenceDate: Date())
        let now = Date()

        lastSessionDSN = sessionStore.dsn?.trimmedNonEmpty
        DeviceRecordingCoordinator.shared.setApplicationActive(UIApplication.shared.applicationState == .active)
        RuntimeDiagnosticsCenter.shared.updateLifecycle(
            scenePhase: "appeared",
            applicationState: SettingsDiagnosticsValueMapper.applicationState(UIApplication.shared.applicationState),
            lastEvent: isInitialAppear ? "root_view_initial_appear" : "root_view_reappear",
            lastForegroundAt: UIApplication.shared.applicationState == .active ? now : nil,
            eventDate: now
        )
        syncGeoService(with: sessionStore.dsn)
        syncLockService(with: sessionStore.dsn, armRecoveryCheck: shouldArmLaunchRecovery)
        syncMediaService(with: sessionStore.dsn)
        clearPersistedBackgroundTimestamp()
        lastBackgroundedAt = nil
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
        syncMediaService(with: newValue)

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
        let now = Date()
        let phase = SettingsDiagnosticsValueMapper.scenePhase(newValue)
        let applicationState = SettingsDiagnosticsValueMapper.applicationState(UIApplication.shared.applicationState)

        if newValue == .background {
            lastBackgroundedAt = now
            persistBackgroundTimestamp(now)
            DeviceRecordingCoordinator.shared.setApplicationActive(false)
            RuntimeDiagnosticsCenter.shared.updateLifecycle(
                scenePhase: phase,
                applicationState: applicationState,
                lastEvent: "scene_background",
                lastBackgroundAt: now,
                eventDate: now
            )
            return
        }

        if newValue == .inactive {
            DeviceRecordingCoordinator.shared.setApplicationActive(false)
            RuntimeDiagnosticsCenter.shared.updateLifecycle(
                scenePhase: phase,
                applicationState: applicationState,
                lastEvent: "scene_inactive",
                eventDate: now
            )
            return
        }

        guard newValue == .active else { return }
        DeviceRecordingCoordinator.shared.setApplicationActive(true)
        RuntimeDiagnosticsCenter.shared.updateLifecycle(
            scenePhase: phase,
            applicationState: applicationState,
            lastEvent: "scene_active",
            lastForegroundAt: now,
            eventDate: now
        )

        if shouldArmRecoveryCheck(referenceDate: Date()) {
            lockCoordinator.armForegroundRecoveryCheck()
        }
        lastBackgroundedAt = nil
        if didHandleInitialAppear {
            clearPersistedBackgroundTimestamp()
        }

        Task {
            await lockCoordinator.refreshNow()
            await DeviceAppLockSyncCoordinator.shared.retryNow()
            await ScreenTimeUsageCoordinator.shared.retryNow()
        }

        syncMediaService(with: sessionStore.dsn)
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

    func syncLockService(with dsn: String?, armRecoveryCheck: Bool = false) {
        lockCoordinator.start(dsn: dsn, armRecoveryCheck: armRecoveryCheck)
    }

    func syncMediaService(with dsn: String?) {
        DeviceRecordingCoordinator.shared.start(dsn: dsn)
    }

    func dsnEquals(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs = rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    func shouldArmRecoveryCheck(referenceDate: Date) -> Bool {
        guard let lastBackgroundedAt else { return false }
        return referenceDate.timeIntervalSince(lastBackgroundedAt) >= recoveryResumeThreshold
    }

    func shouldArmLaunchRecoveryCheck(referenceDate: Date) -> Bool {
        guard let lastBackgroundedAt = persistedBackgroundTimestamp else { return false }
        return referenceDate.timeIntervalSince(lastBackgroundedAt) >= recoveryResumeThreshold
    }

    var recoveryResumeThreshold: TimeInterval {
        45
    }

    var persistedBackgroundTimestamp: Date? {
        let timestamp = UserDefaults.standard.double(forKey: lifecycleBackgroundTimestampKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func persistBackgroundTimestamp(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lifecycleBackgroundTimestampKey)
    }

    func clearPersistedBackgroundTimestamp() {
        UserDefaults.standard.removeObject(forKey: lifecycleBackgroundTimestampKey)
    }

    var lifecycleBackgroundTimestampKey: String {
        "SMARTOILA_LAST_BACKGROUNDED_AT"
    }
}

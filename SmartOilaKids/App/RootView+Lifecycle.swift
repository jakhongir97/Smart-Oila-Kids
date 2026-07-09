import SwiftUI
import UIKit

enum RootLocalServiceRuntime {
    static func shouldRunChildServices(
        debugRoute: DebugRoute?,
        hasLinkedChildDevice: Bool
    ) -> Bool {
        if debugRoute == .main {
            return true
        }

        return debugRoute == nil && hasLinkedChildDevice
    }
}

extension RootView {
    var shouldRunLocalChildServices: Bool {
        RootLocalServiceRuntime.shouldRunChildServices(
            debugRoute: AppRuntime.debugRoute,
            hasLinkedChildDevice: sessionStore.hasLinkedChildDevice
        )
    }

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
        syncGeoService(with: localServiceDSN)
        syncLockService(with: localServiceDSN, armRecoveryCheck: shouldArmLaunchRecovery)
        syncMediaService(with: localServiceDSN)
        clearPersistedBackgroundTimestamp()
        lastBackgroundedAt = nil
        Task {
            await DeviceApplicationUsageReportCoordinator.shared.updateDSN(screenTimeServiceDSN)
            await syncPushToken(with: sessionStore.dsn)
            await PushInboxStore.shared.reconcileAppBadge()
        }
    }

    func handleDSNChange(_ newValue: String?) {
        let normalizedNewDSN = newValue?.trimmedNonEmpty
        let previousDSN = lastSessionDSN?.trimmedNonEmpty
        lastSessionDSN = normalizedNewDSN

        syncGeoService(with: localServiceDSN)
        syncLockService(with: localServiceDSN)
        syncMediaService(with: localServiceDSN)

        Task {
            await DeviceApplicationUsageReportCoordinator.shared.updateDSN(screenTimeServiceDSN)
            await syncPushToken(with: normalizedNewDSN)

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
            OilaTelemetryService.shared.flushNow()
            if shouldRunLocalChildServices,
               AppRuntime.screenTimeFeaturesEnabled {
                Task {
                    await DeviceApplicationUsageReportCoordinator.shared.retryNow()
                }
            }
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
        OilaTelemetryService.shared.refreshLockNow()
        RuntimeDiagnosticsCenter.shared.updateLifecycle(
            scenePhase: phase,
            applicationState: applicationState,
            lastEvent: "scene_active",
            lastForegroundAt: now,
            eventDate: now
        )

        if shouldRunLocalChildServices,
           AppRuntime.screenTimeFeaturesEnabled,
           shouldArmRecoveryCheck(referenceDate: Date()) {
            lockCoordinator.armForegroundRecoveryCheck()
        }
        lastBackgroundedAt = nil
        if didHandleInitialAppear {
            clearPersistedBackgroundTimestamp()
        }

        if shouldRunLocalChildServices,
           AppRuntime.screenTimeFeaturesEnabled {
            Task {
                await lockCoordinator.refreshNow()
                await DeviceAppLockSyncCoordinator.shared.retryNow()
                await DeviceApplicationUsageReportCoordinator.shared.retryNow()
                await ScreenTimeUsageCoordinator.shared.retryNow()
            }
        }

        syncMediaService(with: localServiceDSN)
    }

    func handleLockRefreshNotification(_ notification: Notification) {
        let actions = LockPushRefreshPolicy.actions(
            pushMatchesSession: shouldHandlePush(notification: notification, currentDSN: sessionStore.dsn),
            screenTimeFeaturesEnabled: AppRuntime.screenTimeFeaturesEnabled,
            shouldRunLocalChildServices: shouldRunLocalChildServices
        )
        if actions.refreshOilaLockState {
            // Cuts up-to-30s poll latency to ~0 when the parent locks/unlocks via push.
            // refreshLockNow() no-ops unless the telemetry service is running (i.e. paired).
            oilaTelemetry.refreshLockNow()
        }
        if actions.refreshLegacyLockCoordinator {
            Task {
                await lockCoordinator.refreshNow()
            }
        }
    }
}

private extension RootView {
    func syncGeoService(with dsn: String?) {
        // The REST telemetry pipeline replaces the legacy WebSocket geo service, and only
        // runs once B1–B11 onboarding is complete — so no OS permission prompt fires mid-setup.
        geoBackgroundService.stop()
        // Requires an actual oila360 pairing (tokens), not just a legacy DSN —
        // otherwise every upload would 401 with no recovery path.
        if let dsn, !dsn.isEmpty, sessionStore.onboardingCompleted, sessionStore.oilaPaired {
            OilaTelemetryService.shared.start()
        } else {
            OilaTelemetryService.shared.stop()
        }
    }

    func syncLockService(with dsn: String?, armRecoveryCheck: Bool = false) {
        guard AppRuntime.screenTimeFeaturesEnabled else {
            lockCoordinator.stop()
            return
        }
        lockCoordinator.start(dsn: dsn, armRecoveryCheck: armRecoveryCheck)
    }

    func syncMediaService(with dsn: String?) {
        // Legacy recordings WebSocket backend is dead — keep the coordinator parked (nil → stop).
        DeviceRecordingCoordinator.shared.start(dsn: nil)
        // The covert-recording trigger arrives via push (PushCommandRouter →
        // .pushShouldStartRecording) and uploads via PUT /device/recordings/{id}/complete.
        // Live only with an oila360 device session; onboardingCompleted keeps the mic
        // permission prompt from firing mid-onboarding (mirrors the telemetry gate).
        if let dsn, !dsn.isEmpty, sessionStore.onboardingCompleted, sessionStore.oilaPaired {
            OilaRecordingTriggerService.shared.start(dsn: dsn)
        } else {
            OilaRecordingTriggerService.shared.stop()
        }
    }

    func syncPushToken(with dsn: String?) async {
        // Register the current push token via PATCH /device/fcm-token — only once this
        // install has actually paired (otherwise it would just 401).
        if dsn?.trimmedNonEmpty != nil,
           sessionStore.oilaPaired,
           let token = UserDefaults.standard.string(forKey: "PUSH_NOTIFICATION_TOKEN")?.trimmedNonEmpty {
            try? await OilaDeviceClient.shared.updateFCMToken(token)
        }
    }

    var localServiceDSN: String? {
        shouldRunLocalChildServices ? sessionStore.dsn?.trimmedNonEmpty : nil
    }

    var screenTimeServiceDSN: String? {
        AppRuntime.screenTimeFeaturesEnabled ? localServiceDSN : nil
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

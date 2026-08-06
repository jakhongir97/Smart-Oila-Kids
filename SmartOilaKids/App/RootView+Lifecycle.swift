import SwiftUI
import UIKit

enum RootLocalServiceRuntime {
    static func shouldRunChildServices(
        debugRoute: DebugRoute?,
        hasLinkedChildDevice: Bool
    ) -> Bool {
        debugRoute == nil && hasLinkedChildDevice
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
        RuntimeDiagnosticsCenter.shared.updateLifecycle(
            scenePhase: "appeared",
            applicationState: SettingsDiagnosticsValueMapper.applicationState(UIApplication.shared.applicationState),
            lastEvent: isInitialAppear ? "root_view_initial_appear" : "root_view_reappear",
            lastForegroundAt: UIApplication.shared.applicationState == .active ? now : nil,
            eventDate: now
        )
        syncGeoService(with: localServiceDSN)
        syncLockService(with: localServiceDSN, armRecoveryCheck: shouldArmLaunchRecovery)
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
            // AUDIO survives backgrounding; VIDEO does not.
            //
            // The `audio` background mode is now declared, so iOS keeps the capture session running
            // with the app backgrounded or the screen locked — which is the whole point of the
            // feature and what the Android child app already does via a microphone foreground
            // service. Killing an audio session here would mean a parent can only ever listen while
            // their child happens to be staring at this app.
            //
            // Video is different and NOT a policy choice: iOS suspends camera capture for a
            // backgrounded app no matter what is declared. Letting a video session "continue" would
            // publish a frozen or black track while the parent's UI insists they are watching, so
            // the session is torn down instead and the parent sees the tracks drop — an honest
            // signal they can act on.
            //
            // The visibility promise still holds in both directions: the in-app indicator covers the
            // foreground, and `DeviceAudioStreamManager` posts a persistent system notification for
            // exactly the window the app is not on screen — and ends the session outright if that
            // notification cannot be shown. The policy lives next to the notification it depends on.
            if AppRuntime.audioStreamingEnabled {
                DeviceAudioStreamManager.shared.handleAppDidEnterBackground()
            }
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
            RuntimeDiagnosticsCenter.shared.updateLifecycle(
                scenePhase: phase,
                applicationState: applicationState,
                lastEvent: "scene_inactive",
                eventDate: now
            )
            return
        }

        guard newValue == .active else { return }
        OilaTelemetryService.shared.refreshLockNow()
        OilaTelemetryService.shared.postStatusNow()
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
        // REST telemetry only runs once B1–B11 onboarding is complete — so no OS permission
        // prompt fires mid-setup. Requires an actual oila360 pairing (tokens), not just a
        // legacy DSN — otherwise every upload would 401 with no recovery path.
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

    func syncPushToken(with dsn: String?) async {
        // Register the current push token via PATCH /device/fcm-token — only once this install has
        // actually paired (otherwise it would just 401). Prefer the real FCM registration token;
        // fall back to the raw APNs token ONLY as a pre-Firebase stopgap and never when FCM is
        // configured (FCMPushRegistrar uploads its own token then). Uploading the APNs token while
        // FCM is live would overwrite the deliverable FCM address with an undeliverable one.
        guard dsn?.trimmedNonEmpty != nil, sessionStore.oilaPaired else { return }
        // FCM registration token only — no APNs fallback. The backend delivers via FCM, so a raw
        // APNs hex string in `fcmToken` is undeliverable; sending it made the device look
        // addressable while every parent command was silently dropped. No token is the honest
        // state until FirebaseMessaging is linked.
        guard let token = UserDefaults.standard
            .string(forKey: FCMPushRegistrar.fcmTokenDefaultsKey)?.trimmedNonEmpty else { return }
        try? await OilaDeviceClient.shared.updateFCMToken(token)
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

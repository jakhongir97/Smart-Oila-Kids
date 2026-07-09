import UIKit
import UserNotifications

final class SmartOilaKidsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchDate = Date()
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        DeviceControlEventBridge.shared.start()
        MediaTelemetryInboxBridge.shared.start()
        // Skip the push prompt when previewing a specific screen via SMARTOILA_DEBUG_ROUTE (QA only).
        if !AppRuntime.hasDebugRoute {
            notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        }

        if let remoteInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            PushCommandRouter.handle(
                userInfo: remoteInfo,
                openedFromInteraction: true,
                deliveryContext: .launch
            )
        }

        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateLifecycle(
                applicationState: SettingsDiagnosticsValueMapper.applicationState(application.applicationState),
                lastEvent: launchOptions?[.remoteNotification] == nil ? "launch" : "launch_remote_notification",
                lastForegroundAt: application.applicationState == .active ? launchDate : nil,
                eventDate: launchDate
            )
        }

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Task {
            // Persist for RedeemPairingDto/syncPushToken, and register event-driven so a
            // token that arrives or rotates mid-session lands too.
            UserDefaults.standard.set(token, forKey: "PUSH_NOTIFICATION_TOKEN")
            if UserDefaults.standard.bool(forKey: "BOLAJON_OILA_PAIRED") {
                try? await OilaDeviceClient.shared.updateFCMToken(token)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Registration can fail in simulator or without APNs entitlements.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        let now = Date()
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateLifecycle(
                applicationState: SettingsDiagnosticsValueMapper.applicationState(application.applicationState),
                lastEvent: "app_delegate_did_become_active",
                lastForegroundAt: now,
                eventDate: now
            )
        }
        Task {
            await DeviceControlEventBridge.shared.syncNow()
            await MediaTelemetryInboxBridge.shared.syncNow()
            await PushInboxStore.shared.reconcileAppBadge()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        let now = Date()
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateLifecycle(
                applicationState: SettingsDiagnosticsValueMapper.applicationState(application.applicationState),
                lastEvent: "app_delegate_did_enter_background",
                lastBackgroundAt: now,
                eventDate: now
            )
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        PushCommandRouter.handle(userInfo: userInfo, deliveryContext: .backgroundFetch)
        completionHandler(.newData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        PushCommandRouter.handle(
            userInfo: notification.request.content.userInfo,
            deliveryContext: .foregroundPresentation
        )
        Task {
            await DeviceControlEventBridge.shared.syncNow()
            await MediaTelemetryInboxBridge.shared.syncNow()
        }
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        PushCommandRouter.handle(
            userInfo: response.notification.request.content.userInfo,
            openedFromInteraction: true,
            deliveryContext: .userResponse
        )
        Task {
            await DeviceControlEventBridge.shared.syncNow()
            await MediaTelemetryInboxBridge.shared.syncNow()
        }
        completionHandler()
    }
}

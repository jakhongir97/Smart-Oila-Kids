import UIKit
import UserNotifications
#if canImport(FirebaseMessaging)
import FirebaseCore
import FirebaseMessaging
#endif

final class SmartOilaKidsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchDate = Date()
        // Configure Firebase Cloud Messaging as early as possible so APNs registration below can
        // hand its token to Firebase and mint a real FCM token. No-op until the SDK + plist ship.
        FCMPushRegistrar.shared.configureIfPossible()
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
        // Persist the raw APNs token (diagnostics + legacy pairing stopgap) and hand it to Firebase,
        // which mints the real FCM registration token the backend actually delivers to.
        UserDefaults.standard.set(token, forKey: "PUSH_NOTIFICATION_TOKEN")
        FCMPushRegistrar.shared.setAPNsToken(deviceToken)

        // When FCM is live the real token is uploaded by FCMPushRegistrar. Only fall back to
        // uploading the raw APNs token as a stopgap before the Firebase SDK/plist are present —
        // the backend is FCM-only, so this stopgap cannot actually receive pushes, but it keeps
        // the device's push address non-empty until Firebase lands.
        guard !FCMPushRegistrar.shared.isConfigured else { return }
        if UserDefaults.standard.bool(forKey: "BOLAJON_OILA_PAIRED") {
            Task { try? await OilaDeviceClient.shared.updateFCMToken(token) }
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

/// Bridges Apple Push (APNs) to Firebase Cloud Messaging so the child device obtains a real FCM
/// registration token — the address the oila360 backend uses to deliver every parent-originated
/// command (lock refresh, task deep-link, covert-record trigger, session-invalidate). The backend
/// is FCM-only and mirrors the Android child app's `FirebaseMessagingService`.
///
/// Drop-in activation (both are team/Firebase-owned artifacts):
///   1. Add the `FirebaseMessaging` SPM product to the app target
///      (https://github.com/firebase/firebase-ios-sdk).
///   2. Add the child app's `GoogleService-Info.plist` to the app target (its bundle id must match
///      the app's actual bundle id) and upload the APNs auth key (.p8) to that Firebase project's
///      Cloud Messaging settings (sandbox + production).
///
/// Until both are present this whole type is a compile-clean no-op — the app builds and behaves
/// exactly as before (no push, no crash). No source change is required to switch it on.
final class FCMPushRegistrar: NSObject {
    static let shared = FCMPushRegistrar()

    /// UserDefaults key holding the latest FCM registration token, read by pairing + token sync.
    static let fcmTokenDefaultsKey = "OILA_FCM_TOKEN"

    /// True once Firebase has been configured against a bundled `GoogleService-Info.plist`.
    /// Callers use this to decide whether the FCM path is live (vs. the legacy APNs stopgap).
    private(set) var isConfigured = false

    /// Configure Firebase if the SDK is linked and a `GoogleService-Info.plist` is bundled.
    /// Safe to call unconditionally at launch: a missing SDK or plist is a silent no-op and never
    /// crashes `FirebaseApp.configure()`.
    func configureIfPossible() {
        #if canImport(FirebaseMessaging)
        guard !isConfigured else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            // Plist not shipped yet — keep push disabled rather than crashing FirebaseApp.configure().
            return
        }
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Messaging.messaging().delegate = self
        isConfigured = true
        // Prime an initial token fetch; rotations arrive via didReceiveRegistrationToken.
        Messaging.messaging().token { [weak self] token, _ in
            guard let self, let token else { return }
            self.handleFCMToken(token)
        }
        #endif
    }

    /// Feed the raw APNs device token to Firebase so it can mint/refresh the FCM token.
    /// (Firebase method swizzling is disabled via `FirebaseAppDelegateProxyEnabled=NO`, so the
    /// app delegate forwards the token explicitly.)
    func setAPNsToken(_ deviceToken: Data) {
        #if canImport(FirebaseMessaging)
        guard isConfigured else { return }
        Messaging.messaging().apnsToken = deviceToken
        #endif
    }

    /// Persist the FCM token for pairing and push it to the backend if the device is already paired.
    fileprivate func handleFCMToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.fcmTokenDefaultsKey)
        defaults.set(trimmed, forKey: Self.fcmTokenDefaultsKey)

        // Push to the backend when paired and the token is new (rotation-safe).
        guard trimmed != previous, defaults.bool(forKey: "BOLAJON_OILA_PAIRED") else { return }
        Task {
            try? await OilaDeviceClient.shared.updateFCMToken(trimmed)
        }
    }
}

#if canImport(FirebaseMessaging)
extension FCMPushRegistrar: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        handleFCMToken(fcmToken)
    }
}
#endif

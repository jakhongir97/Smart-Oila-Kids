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
        // Build the live-media manager HERE, before anything can route a wake command.
        //
        // It registers its `pushShouldStart/StopAudioStream` observers in `init`, and its only other
        // references are inside SwiftUI views — `RootView`'s `@StateObject`, whose default is an
        // @autoclosure evaluated on the first BODY RENDER, not when `RootView()` is constructed.
        // When iOS background-launches a terminated app for a silent push it connects no UI scene,
        // so no body is ever rendered: the observers did not exist, and the `stream.start` posted a
        // few lines below (or through `didReceiveRemoteNotification`) reached nobody while
        // diagnostics recorded it as `routed`. That is precisely the case the feature exists for —
        // a parent listening while the child's phone is in a pocket and the app was long evicted.
        // Touching the singleton makes observer registration a launch-time fact instead of a
        // side effect of rendering. It is cheap: no hardware is opened until a command arrives.
        _ = DeviceAudioStreamManager.shared
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        DeviceControlEventBridge.shared.start()
        // Do NOT prompt for notifications at launch — the B2 onboarding step owns that prompt so it
        // arrives in context (a launch-time prompt fired over the A1 language screen before pairing).
        //
        // Registering is NOT prompting. `registerForRemoteNotifications()` shows no UI; it asks
        // APNs for a device token, which is the address the backend needs to deliver a SILENT
        // (content-available) push — and silent delivery requires no alert authorization at all.
        // This used to be gated on `.authorized`, while the notifications onboarding step is
        // optional, so a child who tapped "Not now" once never minted a token and was unreachable
        // for lock refresh, chat and stream commands FOREVER, with nothing in the app able to
        // recover it. The alert grant still governs what the child SEES; it must not govern
        // whether the device can be reached at all.
        if !AppRuntime.hasDebugRoute {
            application.registerForRemoteNotifications()
        }

        if let remoteInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            // A launch via launchOptions[.remoteNotification] is a background (content-available)
            // delivery, not a user tap — taps arrive through userNotificationCenter(_:didReceive:).
            // Marking it as an interaction armed a tasks deep-link the child never requested.
            PushCommandRouter.handle(
                userInfo: remoteInfo,
                openedFromInteraction: false,
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

        // Do NOT upload the raw APNs token as a stand-in for an FCM registration token. The
        // backend field is `fcmToken` and delivery is FCM-only, so a 64-char APNs hex string is not
        // merely useless there -- it makes the device look addressable when it is not, which is why
        // the parent app reports a healthy push channel that silently drops every command. Leave
        // the address EMPTY until FirebaseMessaging is actually linked; empty is the honest value
        // and the backend already tolerates its absence (`fcmToken` is optional at pairing).
        guard FCMPushRegistrar.shared.isConfigured else {
            // APNs handed us an address but Firebase cannot translate it, so this device is not
            // reachable by any parent command. Record it rather than looking healthy.
            let state = FCMPushRegistrar.shared.configurationState.rawValue
            Task { @MainActor in
                RuntimeDiagnosticsCenter.shared.updatePushToken(
                    status: "apns_only",
                    localToken: String(token.prefix(12)) + "…",
                    remoteToken: "-",
                    lastError: "push undeliverable: \(state)"
                )
            }
            return
        }
        if UserDefaults.standard.bool(forKey: "BOLAJON_OILA_PAIRED"),
           let fcmToken = UserDefaults.standard.string(forKey: FCMPushRegistrar.fcmTokenDefaultsKey)?.trimmedNonEmpty {
            Task { try? await OilaDeviceClient.shared.updateFCMToken(fcmToken) }
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
        // Resolve the route BEFORE handling, so the decision to hold the completion handler is made
        // from the same structured event the router will act on.
        let isLiveMediaWake = PushCommandRouter
            .audioRoute(forCommand: PushCommandRouter.parsePayload(from: userInfo).commandHaystack) == .start

        PushCommandRouter.handle(userInfo: userInfo, deliveryContext: .backgroundFetch)

        guard isLiveMediaWake else {
            completionHandler(.newData)
            return
        }

        // Calling the completion handler is a declaration that this push is finished with, and iOS
        // is free to suspend the process the moment it lands. For a `stream.start` that is far too
        // early: the router posts asynchronously, then the manager has a consent check, a mic
        // permission check, a token mint and a LiveKit connect to get through. Reporting "done"
        // ahead of all that invites suspension mid-connect, which the parent sees as a stream that
        // never arrives. Hold the handler until the room is actually up (or the attempt has clearly
        // failed), bounded well inside the ~30s iOS allows.
        Task { @MainActor in
            let startedAt = Date()
            while Date().timeIntervalSince(startedAt) < Self.liveMediaWakeHoldSeconds {
                let state = DeviceAudioStreamManager.shared.state
                if state == .live { break }
                // `.connecting` is the only state worth waiting on. Anything else after a short
                // grace period — still idle because the command was dropped, `.disabled`,
                // `.unsupported`, an error, or a consent sheet nobody is there to tap — will not
                // resolve itself by waiting, so release the process instead of burning its budget.
                if Date().timeIntervalSince(startedAt) >= Self.liveMediaWakeGraceSeconds,
                   state != .connecting {
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            completionHandler(.newData)
        }
    }

    /// Longest a `stream.start` may keep the process awake before its background push is reported
    /// complete. iOS allows roughly 30s; staying well inside it leaves room for the teardown.
    private static let liveMediaWakeHoldSeconds: TimeInterval = 20
    /// How long to wait before concluding that a non-`.connecting` manager is never going to start.
    /// The router posts its notification through an unstructured main-actor hop, so the manager can
    /// legitimately still be `.idle` for a moment after this method returns.
    private static let liveMediaWakeGraceSeconds: TimeInterval = 2

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Our own banners are not commands. The integrity and recovery notifiers both set a
        // `dsn` + `event` userInfo — the very shape the router decodes — so routing them here fed
        // this app's output straight back into its input, duplicating every such event in the
        // inbox and in the badge count. Present them; do not act on them.
        guard !LocalNotificationID.isLocallyScheduled(notification.request.identifier) else {
            completionHandler([.banner, .sound, .badge])
            return
        }
        PushCommandRouter.handle(
            userInfo: notification.request.content.userInfo,
            deliveryContext: .foregroundPresentation
        )
        Task {
            await DeviceControlEventBridge.shared.syncNow()
        }
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Same rule as `willPresent`, and it matters more here: `openedFromInteraction: true` arms
        // a deep-link, so a child tapping one of our own banners could be navigated somewhere the
        // parent never asked for. The refresh below still runs — opening the app is a fine moment
        // to re-sync, whoever posted the banner.
        if !LocalNotificationID.isLocallyScheduled(response.notification.request.identifier) {
            PushCommandRouter.handle(
                userInfo: response.notification.request.content.userInfo,
                openedFromInteraction: true,
                deliveryContext: .userResponse
            )
        }
        Task {
            await DeviceControlEventBridge.shared.syncNow()
        }
        completionHandler()
    }
}

/// Bridges Apple Push (APNs) to Firebase Cloud Messaging so the child device obtains a real FCM
/// registration token — the address the oila360 backend uses to deliver every parent-originated
/// command (lock refresh, task deep-link, covert-record trigger, session-invalidate). The backend
/// is FCM-only and mirrors the Android child app's `FirebaseMessagingService`.
///
/// Activation status:
///   1. DONE — the `FirebaseMessaging` SPM product is linked into the app target
///      (https://github.com/firebase/firebase-ios-sdk, 12.x).
///   2. PENDING (team/Firebase-owned) — add the child app's `GoogleService-Info.plist` to the app
///      target (bundle id must be `uz.smartoila.kids`, in the `oila360` Firebase project) and upload
///      the APNs auth key (.p8) to that project's Cloud Messaging settings (sandbox + production).
///
/// Until the plist ships this type is a compile-clean no-op — the app builds and behaves exactly as
/// before (no push, no crash) — but `configurationState` reports `.missingPlist` and every push
/// diagnostic says so out loud.
///
/// Switching it on needs no SWIFT change, but it is not zero-work: the `.xcodeproj` is
/// hand-maintained and its Resources phase lists every file individually, so dropping
/// `GoogleService-Info.plist` into `Resources/` in Finder does NOT bundle it — the app would stay
/// silently `.missingPlist`. Add it through Xcode, or hand-write the `PBXFileReference`,
/// `PBXBuildFile` and Resources entry. `remote-notification` also has to join `UIBackgroundModes`
/// in that same commit, or iOS will not deliver a silent push to a backgrounded app.
final class FCMPushRegistrar: NSObject {
    static let shared = FCMPushRegistrar()

    /// UserDefaults key holding the latest FCM registration token, read by pairing + token sync.
    static let fcmTokenDefaultsKey = "OILA_FCM_TOKEN"

    /// Why the FCM path is (or is not) live. Recorded into `RuntimeDiagnosticsCenter.pushToken`
    /// so "this device is not addressable" is a readable fact instead of silence. Every non-`live`
    /// case means the backend cannot deliver a single parent command to this device.
    enum ConfigurationState: String {
        /// The FirebaseMessaging SDK is not linked into the binary at all.
        case sdkNotLinked = "sdk_not_linked"
        /// SDK linked, but no `GoogleService-Info.plist` is bundled — Firebase cannot be configured.
        case missingPlist = "missing_google_service_plist"
        /// A plist IS bundled, but it was minted for a different Firebase app entry than this
        /// binary's bundle id. Configuring against it would look healthy and deliver nothing.
        case bundleMismatch = "google_service_plist_bundle_mismatch"
        /// Firebase configured; a real FCM registration token is expected shortly.
        case live
    }

    private(set) var configurationState: ConfigurationState = {
        #if canImport(FirebaseMessaging)
        return .missingPlist
        #else
        return .sdkNotLinked
        #endif
    }()

    /// True once Firebase has been configured against a bundled `GoogleService-Info.plist`.
    /// Callers use this to decide whether the FCM path is live (vs. the legacy APNs stopgap).
    var isConfigured: Bool { configurationState == .live }

    /// Configure Firebase if the SDK is linked and a `GoogleService-Info.plist` is bundled.
    /// Safe to call unconditionally at launch: a missing SDK or plist is a silent no-op and never
    /// crashes `FirebaseApp.configure()`.
    func configureIfPossible() {
        #if canImport(FirebaseMessaging)
        guard !isConfigured else { return }
        guard let plistPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else {
            // Plist not shipped yet — keep push disabled rather than crashing FirebaseApp.configure().
            recordState(.missingPlist)
            return
        }
        // A plist minted for a DIFFERENT app entry configures Firebase without complaint and mints a
        // token we would happily upload — but FCM addresses APNs by the registered app's bundle id,
        // so every push comes back DeviceTokenNotForTopic. Nothing about that is visible on the
        // device, which is exactly the "paired and healthy, yet unreachable" state the omitted
        // `fcmToken` at pairing exists to prevent. Refuse the plist instead of trusting it.
        let declaredBundleID = NSDictionary(contentsOfFile: plistPath)?["BUNDLE_ID"] as? String
        guard declaredBundleID == Bundle.main.bundleIdentifier else {
            recordState(
                .bundleMismatch,
                detail: "plist \(declaredBundleID ?? "nil") != app \(Bundle.main.bundleIdentifier ?? "nil")"
            )
            return
        }
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Messaging.messaging().delegate = self
        recordState(.live)
        // Prime an initial token fetch; rotations arrive via didReceiveRegistrationToken.
        Messaging.messaging().token { [weak self] token, error in
            guard let self else { return }
            guard let token else {
                self.recordTokenFailure(error)
                return
            }
            self.handleFCMToken(token)
        }
        #else
        recordState(.sdkNotLinked)
        #endif
    }

    private func recordState(_ state: ConfigurationState, detail: String? = nil) {
        configurationState = state
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updatePushToken(
                status: state.rawValue,
                endpoint: "device/fcm-token",
                remoteToken: state == .live ? nil : "-",
                lastError: state == .live
                    ? "-"
                    : ["push undeliverable: \(state.rawValue)", detail]
                        .compactMap { $0 }
                        .joined(separator: " — ")
            )
        }
    }

    private func recordTokenFailure(_ error: Error?) {
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updatePushToken(
                status: "token_fetch_failed",
                lastError: error?.localizedDescription ?? "unknown"
            )
        }
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

        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updatePushToken(
                status: "token_ready",
                localToken: String(trimmed.prefix(12)) + "…",
                lastError: "-"
            )
        }

        // Push to the backend when paired and the token is new (rotation-safe).
        guard trimmed != previous, defaults.bool(forKey: "BOLAJON_OILA_PAIRED") else { return }
        Task {
            do {
                try await OilaDeviceClient.shared.updateFCMToken(trimmed)
                await MainActor.run {
                    RuntimeDiagnosticsCenter.shared.updatePushToken(status: "token_uploaded", remoteToken: String(trimmed.prefix(12)) + "…")
                }
            } catch {
                await MainActor.run {
                    RuntimeDiagnosticsCenter.shared.updatePushToken(status: "token_upload_failed", lastError: error.localizedDescription)
                }
            }
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

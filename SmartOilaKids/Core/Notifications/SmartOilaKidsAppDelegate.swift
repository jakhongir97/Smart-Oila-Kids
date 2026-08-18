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
        // FIRST, ahead of everything: drop Keychain credentials left behind by a previous install.
        //
        // This has to run before any other line in this method, because `armTelemetryIfPaired()`
        // below reads the device token and would arm telemetry against an orphaned credential — and
        // it has to run before the app routes at all, which it does: `SessionStore` is a
        // `@StateObject` whose autoclosure is not evaluated until the first scene body, long after
        // the delegate has finished launching.
        SecureTokenStore.purgeCredentialsOrphanedByReinstall()
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
        armTelemetryIfPaired()
        // Drain the FCM outbox at LAUNCH too, not only from `applicationDidBecomeActive`. iOS
        // background-launches this app for silent pushes and for the `location` background mode, and
        // neither delivers a become-active — so on a device that is rarely opened (the normal case
        // for a child's phone left in a pocket) the become-active trigger alone could leave a
        // rotated token unregistered for days, which is precisely when the parent needs to reach it.
        Task { @MainActor in await FCMPushRegistrar.shared.flushPendingTokenRegistration() }
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

    /// Start REST telemetry at LAUNCH rather than waiting for a rendered `RootView`.
    ///
    /// `OilaTelemetryService.shared.start()` had exactly one call site — `syncGeoService`, reached
    /// only from `RootView`'s `.onAppear`. A background launch (silent push, or the location
    /// relaunch this app's `location` background mode exists for) connects no UI scene, so no body
    /// renders and that call never happens. After any reboot, jetsam or force-quit the child's
    /// device therefore reported NOTHING — no location, no `POST /device/status` — until a human
    /// happened to open the app, while the parent's screen showed a stale position with no error.
    ///
    /// The safety half is worse and is why this is not a nice-to-have: `start()` is also the only
    /// caller of `restorePendingSOS()`, so a panic alert queued while offline was never retried on
    /// any background wake and was then discarded as older than `sosMaxAge`.
    ///
    /// Same reasoning as `_ = DeviceAudioStreamManager.shared` above: make it a launch-time fact
    /// instead of a side effect of rendering. `start()` is `guard !isRunning`-idempotent, so the
    /// `.onAppear` path stays correct and simply finds it already running.
    private func armTelemetryIfPaired() {
        // Gate on exactly what `syncGeoService` gates on, plus a real credential. Telemetry before
        // onboarding completes would fire an OS permission prompt mid-setup, and telemetry without
        // tokens would 401 every upload with no recovery path. The token check also closes the
        // migration window where a just-updated legacy install still reads `oilaPaired == true`.
        let defaults = UserDefaults.standard
        guard !AppRuntime.hasDebugRoute,
              defaults.string(forKey: "DSN")?.trimmedNonEmpty != nil,
              defaults.bool(forKey: "BOLAJON_ONBOARDING_COMPLETED"),
              defaults.bool(forKey: "BOLAJON_OILA_PAIRED"),
              SecureTokenStore.oila.accessToken()?.trimmedNonEmpty != nil
        else { return }
        Task { @MainActor in OilaTelemetryService.shared.start() }
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
            // Through the durable outbox, not a bare `Task { try? await … }`. This handler runs at
            // every launch, which is exactly when the network is least likely to be up yet, and the
            // discarded failure is how a rotated token stayed unregistered for the life of an install.
            FCMPushRegistrar.shared.registerToken(fcmToken)
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
        // Retry any FCM registration the server has not acknowledged. Becoming active is the single
        // most reliable "the network is probably up again" signal this app gets — the other one,
        // connectivity returning, is watched by `OilaTelemetryService.applyNetworkType`, which only
        // runs while telemetry is armed.
        Task { @MainActor in await FCMPushRegistrar.shared.flushPendingTokenRegistration() }
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
            // Two silent commands finish their work AFTER `handle` returns, each one main-actor hop
            // away: the chat banner is scheduled there, and `status.report` posts `/device/status`
            // from an observer. Calling the completion handler first tells iOS the push is done and
            // invites suspension before either runs — so the child gets no banner, and the parent's
            // explicit "check in now" produces no check-in. A short bounded hold, not the media one.
            let needsShortHold = PushCommandRouter.schedulesChatBanner(
                userInfo: userInfo, deliveryContext: .backgroundFetch
            ) || PushCommandRouter.isStatusReportCommand(
                PushCommandRouter.parsePayload(from: userInfo).commandHaystack
            )
            if needsShortHold {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.chatBannerHoldSeconds * 1_000_000_000))
                    completionHandler(.newData)
                }
                return
            }
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
    /// Enough for the router's main-actor hop and one `UNUserNotificationCenter.add` (or the status
    /// observer's hop into `reportStatusForProbe`), and short
    /// enough that a chat push never eats a meaningful share of the background budget.
    private static let chatBannerHoldSeconds: TimeInterval = 1.5

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
        if response.notification.request.identifier == LocalNotificationID.chatMessage {
            // Our own "new message" banner. It must not go back through the router (that would
            // re-run the refresh and file our text in the push inbox), but a tap on it has to land
            // where the child expects: the conversation.
            PushCommandRouter.openChatFromLocalBanner(
                userInfo: response.notification.request.content.userInfo
            )
        } else if !LocalNotificationID.isLocallyScheduled(response.notification.request.identifier) {
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

    /// Durable outbox for `PATCH /device/fcm-token`: the token the server has NOT yet acknowledged.
    ///
    /// This is the exact failure the backend owner reproduced on his own device — the token rotated,
    /// the PATCH did not land, and the server went on pushing to a dead address with nothing on
    /// either side saying so. Every previous attempt was launch-scoped and best-effort: a `try?` in
    /// an unstructured `Task` whose failure was thrown away, so an upload that failed because the
    /// child was in a lift was never retried, and the app looked perfectly registered from the
    /// inside. Persisting the attempt is what makes the retry survive the process.
    ///
    /// Exactly ONE entry, deliberately. An older registration token is a dead address, so replaying
    /// it after a newer one would re-create the very state this exists to clear; "queue" here means
    /// "survives relaunch", not "keeps history".
    static let pendingFCMTokenDefaultsKey = "OILA_PENDING_FCM_TOKEN"

    /// Single-flight guard + trailing re-run for the outbox drain, mirroring the telemetry flushes.
    /// Three triggers now converge on it (launch, `didBecomeActive`, connectivity restored) and the
    /// last two fire together the moment a phone leaves a tunnel while being picked up.
    @MainActor private var isFlushingPendingToken = false
    @MainActor private var pendingTokenFlushRequestedAgain = false

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

        // Push to the backend when paired and the token is new (rotation-safe). An unpaired install
        // needs no PATCH at all: `pair()` carries `fcmToken` in the redemption body itself.
        guard trimmed != previous, defaults.bool(forKey: "BOLAJON_OILA_PAIRED") else { return }
        registerToken(trimmed)
    }

    /// Record that `token` still has to reach `PATCH /device/fcm-token`, then try immediately.
    ///
    /// The single entry point for both producers — a Firebase rotation and the APNs registration
    /// callback — so neither can go back to firing a one-shot request whose failure disappears.
    func registerToken(_ token: String) {
        guard let trimmed = token.trimmedNonEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.pendingFCMTokenDefaultsKey)
        Task { @MainActor [weak self] in await self?.flushPendingTokenRegistration() }
    }

    /// Drain the outbox. Safe and cheap to call whenever the app might be able to reach the network:
    /// it returns at the first guard when there is nothing pending.
    @MainActor
    func flushPendingTokenRegistration() async {
        guard !isFlushingPendingToken else {
            // A rotation that arrives mid-flight must not wait for the next foreground: the token in
            // the outbox has changed under the request now in flight, so run once more when it ends.
            pendingTokenFlushRequestedAgain = true
            return
        }
        isFlushingPendingToken = true
        defer { isFlushingPendingToken = false }
        repeat {
            pendingTokenFlushRequestedAgain = false
            await flushPendingTokenRegistrationOnce()
        } while pendingTokenFlushRequestedAgain
    }

    @MainActor
    private func flushPendingTokenRegistrationOnce() async {
        let defaults = UserDefaults.standard
        guard let pending = defaults.string(forKey: Self.pendingFCMTokenDefaultsKey)?.trimmedNonEmpty else { return }
        // An unpaired install has nothing to register the token AGAINST, and uploading it once the
        // next family pairs would attribute this device's push address to whichever Bearer happens
        // to be held then. Same reasoning as the removal-attempt and usage outboxes the disconnect
        // purge drops. Dropping it here rather than in the disconnect keeps the rule with the queue.
        guard defaults.bool(forKey: "BOLAJON_OILA_PAIRED") else {
            defaults.removeObject(forKey: Self.pendingFCMTokenDefaultsKey)
            return
        }
        do {
            try await OilaDeviceClient.shared.updateFCMToken(pending)
            // Cleared ONLY on a server acknowledgement, and only if the entry is still the one that
            // was just acknowledged — a rotation landing mid-request replaces it, and clearing
            // blindly would drop the NEWER token and leave the backend holding the older one.
            if defaults.string(forKey: Self.pendingFCMTokenDefaultsKey)?.trimmedNonEmpty == pending {
                defaults.removeObject(forKey: Self.pendingFCMTokenDefaultsKey)
            }
            RuntimeDiagnosticsCenter.shared.updatePushToken(
                status: "token_uploaded",
                remoteToken: String(pending.prefix(12)) + "…",
                lastError: "-"
            )
        } catch {
            // The entry stays. Status says "pending", not "failed": the difference matters on the
            // diagnostics screen, because a retained entry WILL be retried at the next foreground or
            // the next time connectivity returns, whereas the old one-shot upload never was.
            RuntimeDiagnosticsCenter.shared.updatePushToken(
                status: "token_upload_pending",
                lastError: error.localizedDescription
            )
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

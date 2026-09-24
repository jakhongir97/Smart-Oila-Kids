import AVFoundation
import CoreLocation
import Foundation
import UIKit
import UserNotifications

extension LocationPermissionManager {
    func handleToggleChange(for requirement: PermissionRequirement, isEnabled: Bool) {
        guard isInteractive(requirement) else {
            refreshStatuses()
            return
        }

        if isEnabled {
            performAction(for: requirement)
            scheduleStatusRefresh()
            return
        }

        performDisableAction(for: requirement)
    }

    /// UserDefaults marker: the one-time Always-upgrade prompt has already been issued on this
    /// install. See `requestLocationPermission()`.
    nonisolated static let alwaysPromptIssuedKey = "BOLAJON_ALWAYS_PROMPT_ISSUED"

    func requestLocationPermission() {
        switch locationAuthorizationStatus {
        case .authorizedAlways:
            // Always is granted, so the only reason this row can still be tapped is Precise Location
            // being off. iOS offers no durable prompt for it — `requestTemporaryFullAccuracy-
            // Authorization` lasts until the app is next relaunched — so Settings is the honest
            // destination. Without this branch the button was inert on the one handset shape where
            // the permission looks perfect and every fix is kilometres wide.
            if locationAccuracyAuthorization == .reducedAccuracy {
                openAppSettings()
            }
        case .notDetermined:
            requestWhenInUseLocationAuthorization()
        case .authorizedWhenInUse:
            // iOS shows the "Change to Always?" upgrade prompt ONCE per install. Once the child has
            // answered it with "Keep Only While Using", `requestAlwaysAuthorization()` is a silent
            // no-op forever — so the C5 permission screen kept rendering an Enable button that did
            // nothing at all, on the one row that background location depends on. Ask once; after
            // that send them where the setting actually lives, exactly as the `.denied` branch does.
            if UserDefaults.standard.bool(forKey: Self.alwaysPromptIssuedKey) {
                openAppSettings()
            } else {
                UserDefaults.standard.set(true, forKey: Self.alwaysPromptIssuedKey)
                requestAlwaysLocationAuthorization()
            }
        case .denied, .restricted:
            openAppSettings()
        @unknown default:
            openAppSettings()
        }
    }

    func performAction(for requirement: PermissionRequirement) {
        switch requirement {
        case .location:
            requestLocationPermission()
        case .usageStats:
            requestScreenTimePermission()
        case .notifications:
            requestNotificationPermission()
        case .microphone:
            requestMicrophonePermission()
        case .camera:
            requestCameraPermission()
        }
    }

    // Requesting these used to be a deliberate no-op: v1 shipped no audio or camera feature, and
    // prompting for a permission with no matching Info.plist purpose string is what triggers
    // ITMS-90683. Live audio/video (D-073) now ships with both purpose strings present, so the
    // prompt is legitimate — and a no-op here was worse than useless, because the permission screen
    // renders an "Enable" button for every denied row. Tapping it did nothing at all.

    /// iOS 16 microphone request. Marked deprecated to match the APIs it wraps — Swift suppresses
    /// deprecation warnings inside a declaration that is itself deprecated, so the legacy calls stay
    /// warning-free and this is the single place to delete when the minimum moves to iOS 17.
    @available(iOS, introduced: 16.0, deprecated: 17.0, message: "Superseded by AVAudioApplication.")
    private func requestLegacyMicrophonePermission() {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            break
        case .undetermined:
            session.requestRecordPermission { [weak self] _ in
                DispatchQueue.main.async { self?.refreshStatuses() }
            }
        case .denied:
            // Once denied, iOS never shows the prompt again — and by now the Settings row exists.
            openAppSettings()
        @unknown default:
            openAppSettings()
        }
    }

    func requestMicrophonePermission() {
        guard #available(iOS 17.0, *) else {
            // iOS 16 gets the same branching through the pre-`AVAudioApplication` API rather than
            // being sent straight to Settings. That shortcut was a dead end: iOS does not list a
            // Microphone row for an app that has never requested the permission, so a child on iOS
            // 16 — the app's own stated minimum — tapped "Enable" and arrived at a Settings page
            // with nothing on it to turn on. Asking first is both the working path and the one that
            // creates the row for the Settings fallback to point at.
            requestLegacyMicrophonePermission()
            return
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] _ in
                DispatchQueue.main.async { self?.refreshStatuses() }
            }
        case .denied:
            // iOS only ever shows the system prompt once; after a denial the only route is Settings.
            openAppSettings()
        @unknown default:
            openAppSettings()
        }
    }

    func requestCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshStatuses() }
            }
        case .denied, .restricted:
            openAppSettings()
        @unknown default:
            openAppSettings()
        }
    }
}

// MARK: - Onboarding: ask and wait for the answer

/// How one onboarding `ask` ended. The step decides what to SHOW from the live status, never from
/// this; the outcome only says the request is over (the spinner stops) and, for Screen Time, what the
/// child answered — the one permission whose answer the status does not reveal.
enum PermissionAskOutcome: Equatable {
    /// The system prompt was shown and answered, or there was nothing left to ask.
    case answered
    /// The prompt can no longer be shown, so the app's Settings pane was opened instead.
    case openedSettings
    /// iOS took the request and showed nothing: the once-per-install "Change to Always?" upgrade was
    /// already spent before our marker recorded it, or the grant is Allow Once.
    case promptNotShown
    /// `sawAlert`: the app was deactivated while the request was out — Apple's sheet (then Face ID)
    /// took the screen, so a person answered. See `BolajonOnboardingModel.screenTimeVerdict`.
    case screenTime(ScreenTimeRequestOutcome, sawAlert: Bool)
}

/// A location request waiting for iOS's answer. See `LocationPermissionManager.ask(_:always:)`.
struct PendingLocationAsk {
    let id = UUID()
    let statusAtRequest: CLAuthorizationStatus
    let continuation: CheckedContinuation<PermissionAskOutcome, Never>
    /// The system alert took the screen (`willResignActive`). Until then the request may be one iOS
    /// silently ignores, which is what the timeout below is for.
    var sawResignActive = false
    var timeout: Task<Void, Never>?
}

extension LocationPermissionManager {
    /// How long a location request may go without the system alert appearing before it is read as
    /// "iOS ignored it". The alert takes a few hundred milliseconds to come up; the ignored cases
    /// never bring one.
    nonisolated static let locationPromptWait: TimeInterval = 2

    /// The onboarding form of `performAction(for:)`: the same branching on the real status, but it
    /// RETURNS once iOS has answered — which is what lets a step stay on screen until the permission
    /// exists (Ibrohim, 2026-09-25: a step moved on after "Don't Allow", so the child never saw that
    /// anything was missing). `performAction` stays fire-and-forget for C5, whose rows just re-render.
    ///
    /// `always` is the background-location step: from While Using it asks for the upgrade once, and
    /// sends the child to Settings after that, exactly as `requestLocationPermission()` does.
    func ask(_ requirement: PermissionRequirement, always: Bool = false) async -> PermissionAskOutcome {
        switch requirement {
        case .notifications:
            return await askNotifications()
        case .location:
            return await askLocation(always: always)
        case .usageStats:
            let deactivationsBefore = resignActiveCount
            let outcome = await ScreenTimeAuthorizationManager.shared.requestAuthorization()
            setScreenTimePermissionStatus(ScreenTimeAuthorizationManager.shared.status)
            refreshStatuses()
            return .screenTime(outcome, sawAlert: resignActiveCount != deactivationsBefore)
        case .microphone:
            return await askMicrophone()
        case .camera:
            return await askCamera()
        }
    }

    /// Ends the pending location ask, once. A stale settle (scheduled for an ask that has already
    /// been replaced) passes the id it was scheduled for and is ignored.
    func settlePendingLocationAsk(_ outcome: PermissionAskOutcome, id: UUID? = nil) {
        guard let pending = pendingLocationAsk else { return }
        if let id, id != pending.id { return }
        pendingLocationAsk = nil
        pending.timeout?.cancel()
        pending.continuation.resume(returning: outcome)
    }

    /// From `locationManagerDidChangeAuthorization`: an answer that changed the status settles the
    /// ask. iOS calls the delegate only on a CHANGE, so "Keep Only While Using" never arrives here —
    /// the scene hooks below cover it.
    func locationAuthorizationDidChangeForPendingAsk() {
        guard let pending = pendingLocationAsk,
              currentLocationAuthorizationStatus() != pending.statusAtRequest else { return }
        settlePendingLocationAsk(.answered)
    }

    /// A system alert deactivates the scene: the request was shown, so no timeout may call it ignored.
    func pendingLocationAskWillResignActive() {
        pendingLocationAsk?.sawResignActive = true
    }

    /// The alert closed. Settled a moment later, not at once: when the answer DID change the status,
    /// the delegate callback lands just after this notification, and settling first would flash the
    /// unanswered step for a frame.
    func pendingLocationAskDidBecomeActive() {
        guard let pending = pendingLocationAsk, pending.sawResignActive else { return }
        let id = pending.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.settlePendingLocationAsk(.answered, id: id)
        }
    }

    private func askNotifications() async -> PermissionAskOutcome {
        // The live answer, not the published copy: that starts at `.notDetermined` and is filled in
        // asynchronously, and `requestAuthorization` against a phone that already said no returns
        // false without a prompt — a button that visibly does nothing.
        let status = await notificationStatus()
        setNotificationAuthorizationStatus(status)
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .answered
        case .notDetermined:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            // Register regardless of the answer — see `requestNotificationPermission()`: the token is
            // what makes the phone reachable by a SILENT push, which needs no alert authorization.
            UIApplication.shared.registerForRemoteNotifications()
            setNotificationAuthorizationStatus(await notificationStatus())
            refreshStatuses()
            return .answered
        case .denied:
            openNotificationSettings()
            return .openedSettings
        @unknown default:
            openNotificationSettings()
            return .openedSettings
        }
    }

    private func askLocation(always: Bool) async -> PermissionAskOutcome {
        // Location Services off device-wide reads as `.denied` for every app, and no prompt of ours
        // can turn the master switch on. Read off the main thread: it is a synchronous XPC call, the
        // kind the 2026-09-24 freeze work moved off it everywhere else.
        guard await DeviceDiagnosticsReporter.readLocationServicesEnabled() else {
            openAppSettings()
            return .openedSettings
        }
        let status = currentLocationAuthorizationStatus()
        switch status {
        case .notDetermined:
            // While Using first, on both steps: iOS offers "Always" only as an upgrade of it.
            return await awaitLocationAnswer(from: status) { $0.requestWhenInUseLocationAuthorization() }
        case .authorizedWhenInUse:
            guard always else { return .answered }
            // The same once-per-install rule as `requestLocationPermission()`.
            if UserDefaults.standard.bool(forKey: Self.alwaysPromptIssuedKey) {
                openAppSettings()
                return .openedSettings
            }
            let outcome = await awaitLocationAnswer(from: status) { $0.requestAlwaysLocationAuthorization() }
            // The marker records an alert that was SEEN. Written before the request, an upgrade iOS
            // ignored (Allow Once) spent it for good, and every later attempt went to Settings
            // without iOS ever having asked. An ignored request is the run's business instead
            // (`BolajonOnboardingModel.alwaysPromptIgnored`).
            if outcome == .answered {
                UserDefaults.standard.set(true, forKey: Self.alwaysPromptIssuedKey)
            }
            return outcome
        case .authorizedAlways:
            return .answered
        case .denied, .restricted:
            openAppSettings()
            return .openedSettings
        @unknown default:
            openAppSettings()
            return .openedSettings
        }
    }

    /// Issues `request` and suspends until the FIRST of: the status changes (delegate), the alert
    /// closes (resign → become active), or `locationPromptWait` passes with no alert at all.
    private func awaitLocationAnswer(
        from status: CLAuthorizationStatus,
        request: @escaping (LocationPermissionManager) -> Void
    ) async -> PermissionAskOutcome {
        // A previous ask never outlives a new one.
        settlePendingLocationAsk(.answered)
        return await withCheckedContinuation { continuation in
            var pending = PendingLocationAsk(statusAtRequest: status, continuation: continuation)
            let id = pending.id
            pending.timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.locationPromptWait * 1_000_000_000))
                guard !Task.isCancelled, let self,
                      let current = self.pendingLocationAsk, current.id == id,
                      !current.sawResignActive else { return }
                self.settlePendingLocationAsk(.promptNotShown, id: id)
            }
            pendingLocationAsk = pending
            request(self)
        }
    }

    /// iOS 17+ microphone ask. Same branching as `requestMicrophonePermission()`.
    private func askMicrophone() async -> PermissionAskOutcome {
        guard #available(iOS 17.0, *) else {
            return await askLegacyMicrophone()
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            _ = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            openAppSettings()
            return .openedSettings
        @unknown default:
            openAppSettings()
            return .openedSettings
        }
        refreshStatuses()
        return .answered
    }

    /// iOS 16. Deprecated for the same reason as `requestLegacyMicrophonePermission()`.
    @available(iOS, introduced: 16.0, deprecated: 17.0, message: "Superseded by AVAudioApplication.")
    private func askLegacyMicrophone() async -> PermissionAskOutcome {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            break
        case .undetermined:
            _ = await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            openAppSettings()
            return .openedSettings
        @unknown default:
            openAppSettings()
            return .openedSettings
        }
        refreshStatuses()
        return .answered
    }

    private func askCamera() async -> PermissionAskOutcome {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            openAppSettings()
            return .openedSettings
        @unknown default:
            openAppSettings()
            return .openedSettings
        }
        refreshStatuses()
        return .answered
    }
}

private extension LocationPermissionManager {
    func performDisableAction(for requirement: PermissionRequirement) {
        switch requirement {
        case .location, .microphone, .camera:
            openAppSettings()
        case .usageStats:
            Task { @MainActor [weak self] in
                await ScreenTimeAuthorizationManager.shared.revokeAuthorization()
                self?.setScreenTimePermissionStatus(ScreenTimeAuthorizationManager.shared.status)
                self?.refreshStatuses()
            }
        case .notifications:
            openNotificationSettings()
        }
    }

    func scheduleStatusRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshStatuses()
        }
    }

    func requestScreenTimePermission() {
        Task { @MainActor [weak self] in
            await ScreenTimeAuthorizationManager.shared.requestAuthorization()
            self?.setScreenTimePermissionStatus(ScreenTimeAuthorizationManager.shared.status)
            self?.refreshStatuses()
        }
    }

    func requestNotificationPermission() {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                DispatchQueue.main.async {
                    // Register regardless of the answer. The token is what makes the device
                    // reachable by a SILENT push, which needs no alert authorization — gating it
                    // on `granted` meant declining the banner also, invisibly, opted the child out
                    // of lock refresh, chat and live-stream commands.
                    UIApplication.shared.registerForRemoteNotifications()
                    self.refreshStatuses()
                }
            }
        case .denied:
            openNotificationSettings()
        @unknown default:
            openNotificationSettings()
        }
    }

    func openNotificationSettings() {
        if #available(iOS 16.0, *),
           let url = URL(string: UIApplication.openNotificationSettingsURLString),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return
        }

        openAppSettings()
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}

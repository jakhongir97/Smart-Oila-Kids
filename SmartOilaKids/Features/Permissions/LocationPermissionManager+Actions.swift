import AVFoundation
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
            break
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

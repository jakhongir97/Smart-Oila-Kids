import AVFAudio
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

    func requestLocationPermission() {
        switch locationAuthorizationStatus {
        case .authorizedAlways:
            break
        case .notDetermined, .authorizedWhenInUse:
            requestAlwaysLocationAuthorization()
        case .denied, .restricted:
            openAppSettings()
        @unknown default:
            openAppSettings()
        }
    }

    func performAction(for requirement: PermissionRequirement) {
        switch requirement {
        case .displayOverApps:
            // iOS does not expose these Android-style permissions.
            return
        case .usageStats:
            requestScreenTimePermission()
        case .location:
            requestLocationPermission()
        case .batteryOptimization:
            if isLowPowerModeEnabled {
                openAppSettings()
            }
        case .microphone:
            requestMicrophonePermission()
        case .camera:
            requestCameraPermission()
        case .backgroundTransfer:
            if backgroundRefreshStatus != .available {
                openAppSettings()
            }
        case .notifications:
            requestNotificationPermission()
        }
    }
}

private extension LocationPermissionManager {
    func performDisableAction(for requirement: PermissionRequirement) {
        switch requirement {
        case .displayOverApps:
            return
        case .usageStats:
            Task { @MainActor [weak self] in
                await ScreenTimeAuthorizationManager.shared.revokeAuthorization()
                self?.setScreenTimePermissionStatus(ScreenTimeAuthorizationManager.shared.status)
                self?.refreshStatuses()
            }
        case .location, .microphone, .camera, .backgroundTransfer:
            openAppSettings()
        case .notifications:
            openNotificationSettings()
        case .batteryOptimization:
            // Low Power Mode is a global device state, not an app permission.
            // Opening Settings is the closest public path available from the app.
            openAppSettings()
        }
    }

    func scheduleStatusRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshStatuses()
        }
    }

    func requestMicrophonePermission() {
        switch microphonePermission {
        case .granted:
            break
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] _ in
                Task { @MainActor in
                    self?.refreshStatuses()
                }
            }
        case .denied:
            openAppSettings()
        @unknown default:
            openAppSettings()
        }
    }

    func requestCameraPermission() {
        switch cameraAuthorizationStatus {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshStatuses()
                }
            }
        case .denied, .restricted:
            openAppSettings()
        @unknown default:
            openAppSettings()
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
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    if granted {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
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

import AVFAudio
import Foundation
import UIKit
import UserNotifications

extension LocationPermissionManager {
    func requestLocationPermission() {
        switch locationAuthorizationStatus {
        case .authorizedAlways:
            break
        case .notDetermined, .authorizedWhenInUse:
            requestAlwaysLocationAuthorization()
        case .denied, .restricted:
            openSettings()
        @unknown default:
            openSettings()
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
                openSettings()
            }
        case .microphone:
            requestMicrophonePermission()
        case .backgroundTransfer:
            if backgroundRefreshStatus != .available {
                openSettings()
            }
        case .notifications:
            requestNotificationPermission()
        }
    }
}

private extension LocationPermissionManager {
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
            openSettings()
        @unknown default:
            openSettings()
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
            openSettings()
        @unknown default:
            openSettings()
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}

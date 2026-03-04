import AVFAudio
import CoreLocation
import Foundation
import UIKit
import UserNotifications

enum PermissionRequirement: Int, CaseIterable, Identifiable {
    case displayOverApps
    case location
    case batteryOptimization
    case microphone
    case usageStats
    case backgroundTransfer
    case notifications

    var id: Int { rawValue }

    var titleKey: String {
        "permissions.item_\(rawValue + 1)"
    }

    var detailBodyKey: String {
        "permissions.details.body_\(rawValue + 1)"
    }

    var detailStepKey: String {
        "permissions.details.step_\(rawValue + 1)"
    }
}

@MainActor
final class LocationPermissionManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var locationIsNotGranted = true
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var microphonePermission: AVAudioSession.RecordPermission = .undetermined
    @Published private(set) var backgroundRefreshStatus: UIBackgroundRefreshStatus = .available
    @Published private(set) var isLowPowerModeEnabled = false

    override init() {
        super.init()
        locationManager.delegate = self
        registerObservers()
        refreshStatuses()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshStatuses()
    }

    func refreshStatuses() {
        locationAuthorizationStatus = locationManager.authorizationStatus
        locationIsNotGranted = !isLocationSatisfied

        microphonePermission = AVAudioSession.sharedInstance().recordPermission
        backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        Task {
            let status = await notificationStatus()
            await MainActor.run {
                self.notificationAuthorizationStatus = status
            }
        }
    }

    func requestLocationPermission() {
        switch locationAuthorizationStatus {
        case .authorizedAlways:
            break
        case .notDetermined, .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            openSettings()
        @unknown default:
            openSettings()
        }
    }

    func performAction(for requirement: PermissionRequirement) {
        switch requirement {
        case .displayOverApps, .usageStats:
            // iOS does not expose these Android-style permissions.
            return
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

    func isInteractive(_ requirement: PermissionRequirement) -> Bool {
        switch requirement {
        case .displayOverApps, .usageStats:
            return false
        default:
            return true
        }
    }

    func isSatisfied(_ requirement: PermissionRequirement) -> Bool {
        switch requirement {
        case .displayOverApps:
            return true
        case .location:
            return isLocationSatisfied
        case .batteryOptimization:
            return !isLowPowerModeEnabled
        case .microphone:
            return microphonePermission == .granted
        case .usageStats:
            return true
        case .backgroundTransfer:
            return backgroundRefreshStatus == .available
        case .notifications:
            return isNotificationSatisfied
        }
    }

    var allChecklistSatisfied: Bool {
        PermissionRequirement.allCases.allSatisfy { isSatisfied($0) }
    }

    func statusText(for requirement: PermissionRequirement) -> String {
        switch requirement {
        case .displayOverApps, .usageStats:
            return L10n.tr("permissions.status_not_required_ios")
        case .location:
            if isLocationSatisfied {
                return L10n.tr("permissions.status_granted")
            }
            switch locationAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.status_tap_to_allow")
            case .authorizedWhenInUse:
                return L10n.tr("permissions.status_location_always_required")
            case .denied, .restricted:
                return L10n.tr("permissions.status_open_settings")
            case .authorizedAlways:
                return L10n.tr("permissions.status_granted")
            @unknown default:
                return L10n.tr("permissions.status_open_settings")
            }
        case .batteryOptimization:
            return isLowPowerModeEnabled
                ? L10n.tr("permissions.status_low_power_disable")
                : L10n.tr("permissions.status_granted")
        case .microphone:
            switch microphonePermission {
            case .granted:
                return L10n.tr("permissions.status_granted")
            case .undetermined:
                return L10n.tr("permissions.status_tap_to_allow")
            case .denied:
                return L10n.tr("permissions.status_open_settings")
            @unknown default:
                return L10n.tr("permissions.status_open_settings")
            }
        case .backgroundTransfer:
            switch backgroundRefreshStatus {
            case .available:
                return L10n.tr("permissions.status_granted")
            case .denied, .restricted:
                return L10n.tr("permissions.status_open_settings")
            @unknown default:
                return L10n.tr("permissions.status_open_settings")
            }
        case .notifications:
            if isNotificationSatisfied {
                return L10n.tr("permissions.status_granted")
            }
            switch notificationAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.status_tap_to_allow")
            case .denied:
                return L10n.tr("permissions.status_open_settings")
            case .authorized, .provisional, .ephemeral:
                return L10n.tr("permissions.status_granted")
            @unknown default:
                return L10n.tr("permissions.status_open_settings")
            }
        }
    }

    func primaryActionTitle(for requirement: PermissionRequirement) -> String? {
        guard isInteractive(requirement), !isSatisfied(requirement) else { return nil }

        switch requirement {
        case .displayOverApps, .usageStats:
            return nil
        case .location:
            switch locationAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.action_allow_location")
            case .authorizedWhenInUse:
                return L10n.tr("permissions.action_allow_location_always")
            case .denied, .restricted:
                return L10n.tr("permissions.action_open_settings")
            case .authorizedAlways:
                return nil
            @unknown default:
                return L10n.tr("permissions.action_open_settings")
            }
        case .batteryOptimization:
            return isLowPowerModeEnabled ? L10n.tr("permissions.action_open_settings") : nil
        case .microphone:
            switch microphonePermission {
            case .undetermined:
                return L10n.tr("permissions.action_allow_microphone")
            case .denied:
                return L10n.tr("permissions.action_open_settings")
            case .granted:
                return nil
            @unknown default:
                return L10n.tr("permissions.action_open_settings")
            }
        case .backgroundTransfer:
            switch backgroundRefreshStatus {
            case .available:
                return nil
            case .denied, .restricted:
                return L10n.tr("permissions.action_open_settings")
            @unknown default:
                return L10n.tr("permissions.action_open_settings")
            }
        case .notifications:
            switch notificationAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.action_allow_notifications")
            case .denied:
                return L10n.tr("permissions.action_open_settings")
            case .authorized, .provisional, .ephemeral:
                return nil
            @unknown default:
                return L10n.tr("permissions.action_open_settings")
            }
        }
    }

    private var isLocationSatisfied: Bool {
        locationAuthorizationStatus == .authorizedAlways
    }

    private var isNotificationSatisfied: Bool {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func registerObservers() {
        let center = NotificationCenter.default

        let didBecomeActive = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatuses()
            }
        }

        let powerStateChanged = center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatuses()
            }
        }

        observers.append(didBecomeActive)
        observers.append(powerStateChanged)
    }

    private func requestMicrophonePermission() {
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

    private func requestNotificationPermission() {
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

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    private func notificationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private let locationManager = CLLocationManager()
    private var observers: [NSObjectProtocol] = []
}

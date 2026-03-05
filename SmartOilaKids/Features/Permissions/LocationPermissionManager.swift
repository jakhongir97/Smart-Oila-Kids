import AVFAudio
import CoreLocation
import Foundation
import UIKit
import UserNotifications

@MainActor
final class LocationPermissionManager: NSObject, ObservableObject {
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
        observers.removeAll()
    }

    func setLocationIsNotGranted(_ value: Bool) {
        locationIsNotGranted = value
    }

    func setLocationAuthorizationStatus(_ value: CLAuthorizationStatus) {
        locationAuthorizationStatus = value
    }

    func setNotificationAuthorizationStatus(_ value: UNAuthorizationStatus) {
        notificationAuthorizationStatus = value
    }

    func setMicrophonePermission(_ value: AVAudioSession.RecordPermission) {
        microphonePermission = value
    }

    func setBackgroundRefreshStatus(_ value: UIBackgroundRefreshStatus) {
        backgroundRefreshStatus = value
    }

    func setLowPowerModeEnabled(_ value: Bool) {
        isLowPowerModeEnabled = value
    }

    func currentLocationAuthorizationStatus() -> CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    func requestAlwaysLocationAuthorization() {
        locationManager.requestAlwaysAuthorization()
    }

    func addObserverToken(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    func statusSnapshot() -> PermissionStatusSnapshot {
        PermissionStatusSnapshot(
            locationAuthorizationStatus: locationAuthorizationStatus,
            notificationAuthorizationStatus: notificationAuthorizationStatus,
            microphonePermission: microphonePermission,
            backgroundRefreshStatus: backgroundRefreshStatus,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        )
    }

    private let locationManager = CLLocationManager()
    private var observers: [NSObjectProtocol] = []
}

import AVFAudio
import AVFoundation
import CoreLocation
import Foundation
import UIKit
import UserNotifications

@MainActor
final class LocationPermissionManager: NSObject, ObservableObject {
    @Published private(set) var locationIsNotGranted = true
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var locationAccuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var microphonePermission: AVAudioSession.RecordPermission = .undetermined
    @Published private(set) var cameraAuthorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var screenTimePermissionStatus: ScreenTimePermissionStatus = .notDetermined
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

    func setLocationAccuracyAuthorization(_ value: CLAccuracyAuthorization) {
        locationAccuracyAuthorization = value
    }

    func setNotificationAuthorizationStatus(_ value: UNAuthorizationStatus) {
        notificationAuthorizationStatus = value
    }

    func setMicrophonePermission(_ value: AVAudioSession.RecordPermission) {
        microphonePermission = value
    }

    func setCameraAuthorizationStatus(_ value: AVAuthorizationStatus) {
        cameraAuthorizationStatus = value
    }


    func setScreenTimePermissionStatus(_ value: ScreenTimePermissionStatus) {
        screenTimePermissionStatus = value
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

    func currentLocationAccuracyAuthorization() -> CLAccuracyAuthorization {
        locationManager.accuracyAuthorization
    }

    func requestWhenInUseLocationAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// Raw CoreLocation escalation. NOTE: this only prompts from `.notDetermined` or
    /// `.authorizedWhenInUse` — from `.denied`/`.restricted` iOS ignores it silently. Call it
    /// directly only when the status is known to be promptable; UI should go through
    /// `performAction(for: .location)`, whose `requestLocationPermission()` branches on the real
    /// status and falls through to Settings when the prompt can no longer be shown.
    func requestAlwaysLocationAuthorization() {
        locationManager.requestAlwaysAuthorization()
    }

    func addObserverToken(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    func statusSnapshot() -> PermissionStatusSnapshot {
        PermissionStatusSnapshot(
            locationAuthorizationStatus: locationAuthorizationStatus,
            locationAccuracyAuthorization: locationAccuracyAuthorization,
            notificationAuthorizationStatus: notificationAuthorizationStatus,
            microphonePermission: microphonePermission,
            cameraAuthorizationStatus: cameraAuthorizationStatus,
            screenTimePermissionStatus: screenTimePermissionStatus,
            backgroundRefreshStatus: backgroundRefreshStatus,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        )
    }

    private let locationManager = CLLocationManager()
    private var observers: [NSObjectProtocol] = []
}

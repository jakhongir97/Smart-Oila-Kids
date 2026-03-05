import AVFAudio
import CoreLocation
import Foundation
import UIKit

extension GeoBackgroundService {
    func configureDeviceObservers() {
        UIDevice.current.isBatteryMonitoringEnabled = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceStateChange),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceStateChange),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil
        )
    }

    func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = configuration.minDistance
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func configurePathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handlePathUpdate()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }
}

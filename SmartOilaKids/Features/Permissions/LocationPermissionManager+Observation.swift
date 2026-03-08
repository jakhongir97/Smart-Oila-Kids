import CoreLocation
import Foundation
import UIKit

extension LocationPermissionManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshStatuses()
    }
}

extension LocationPermissionManager {
    func registerObservers() {
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

        let willResignActive = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
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

        let screenCaptureChanged = center.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatuses()
            }
        }

        addObserverToken(didBecomeActive)
        addObserverToken(willResignActive)
        addObserverToken(powerStateChanged)
        addObserverToken(screenCaptureChanged)
    }
}

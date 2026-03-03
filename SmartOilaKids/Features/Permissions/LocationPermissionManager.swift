import CoreLocation
import Foundation

@MainActor
final class LocationPermissionManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var locationIsNotGranted: Bool

    override init() {
        self.locationIsNotGranted = !UserDefaults.standard.bool(forKey: Self.keys.locationPermissionRequested)
        super.init()
        manager.delegate = self
    }

    func requestLocationPermission() {
        UserDefaults.standard.set(true, forKey: Self.keys.locationPermissionRequested)
        locationIsNotGranted = false
        manager.requestAlwaysAuthorization()
    }

    private let manager = CLLocationManager()

    private enum keys {
        static let locationPermissionRequested = "LOCATION_PERMISSION_REQUESTED"
    }
}

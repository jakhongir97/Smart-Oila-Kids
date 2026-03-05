import CoreLocation
import Foundation

struct GeoServiceState {
    var currentDSN: String?
    var currentBaseIndex = 0
    var isRunning = false
    var isDisconnectRequested = false
    var reconnectAttemptCount = 0
    var lastKnownLocation: CLLocation?
    var lastSystemInfoSnapshot: GeoSystemInfoSnapshot?
}

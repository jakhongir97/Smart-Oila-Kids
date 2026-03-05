import CoreLocation
import Foundation

struct GeoServiceConfiguration {
    let minDistance: CLLocationDistance
    let periodicLocationInterval: TimeInterval
    let systemInfoInterval: TimeInterval
    let reconnectBaseDelay: TimeInterval
    let reconnectMaxDelay: TimeInterval

    static let `default` = GeoServiceConfiguration(
        minDistance: 10,
        periodicLocationInterval: 180,
        systemInfoInterval: 60,
        reconnectBaseDelay: 2,
        reconnectMaxDelay: 20
    )
}

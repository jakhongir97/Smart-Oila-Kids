import Foundation

struct GeoDebugSnapshot: Equatable {
    var status: String = "idle"
    var endpoint: String = "-"
    var lastPayload: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
    var lastLatitude: Double? = nil
    var lastLongitude: Double? = nil
    var lastLocationAt: Date? = nil
    var lastHorizontalAccuracy: Double? = nil
}

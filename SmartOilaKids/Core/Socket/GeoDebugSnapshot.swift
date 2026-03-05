import Foundation

struct GeoDebugSnapshot: Equatable {
    var status: String = "idle"
    var endpoint: String = "-"
    var lastPayload: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
}

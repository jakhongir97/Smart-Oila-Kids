import Foundation

enum GeoConnectionStatus: String {
    case starting
    case stopped
    case connecting
    case connected
    case reconnecting
    case failed
    case queued
    case serializeFailed = "serialize_failed"
    case sendFailed = "send_failed"
}

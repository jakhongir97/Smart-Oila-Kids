import Foundation

/// PARKED. Legacy realtime applications-sync WebSocket — decommissioned backend; see
/// `DeviceLockWebSocketService`. Kept as the coordinator's realtime seam.
final class DeviceApplicationsSyncWebSocketService {
    var onSyncRequested: ((Bool) -> Void)?

    func connect(dsn: String) {}

    func disconnect() {}
}

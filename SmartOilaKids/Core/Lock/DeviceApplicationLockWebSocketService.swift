import Foundation

/// PARKED. Legacy realtime app-lock WebSocket — decommissioned backend; see
/// `DeviceLockWebSocketService`. Kept as the coordinator's realtime seam.
final class DeviceApplicationLockWebSocketService {
    var onLockEvent: ((DeviceApplicationLockEvent, Bool) -> Void)?

    func connect(dsn: String) {}

    func disconnect() {}
}

import Foundation

/// PARKED. The legacy realtime lock WebSocket (`backend.smart-oila.uz`) is decommissioned;
/// lock state is driven by the oila360 REST poll + push refresh. The class remains so
/// `DeviceLockCoordinator` keeps its realtime seam (tests inject events through the
/// callback); `connect` is intentionally a no-op.
final class DeviceLockWebSocketService {
    var onGlobalLockStatusChange: ((Bool, Bool) -> Void)?

    func connect(dsn: String) {}

    func disconnect() {}
}

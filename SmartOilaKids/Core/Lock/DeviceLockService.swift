import Foundation

protocol DeviceLockServicing {
    func fetchFullLockStatus(dsn: String) async throws -> DeviceFullLockStatus
    func fetchGlobalLockStatus(dsn: String) async throws -> Bool
}

/// PARKED transport. The legacy `backend.smart-oila.uz` lock REST endpoints are
/// decommissioned, and this whole path only runs behind
/// `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED` (off in v1). When per-app Screen-Time
/// enforcement ships (v1.1, Family Controls entitlement), reimplement against the
/// oila360 device API (`GET /device/lock/state`, `POST /device/apps/usage`) instead.
/// Throwing keeps `DeviceLockCoordinator`'s error path ("keep current lock state")
/// intact if the flag is ever flipped before the new transport lands.
final class DeviceLockService: DeviceLockServicing {
    init() {}

    func fetchFullLockStatus(dsn: String) async throws -> DeviceFullLockStatus {
        throw NetworkError.invalidURL
    }

    func fetchGlobalLockStatus(dsn: String) async throws -> Bool {
        throw NetworkError.invalidURL
    }
}

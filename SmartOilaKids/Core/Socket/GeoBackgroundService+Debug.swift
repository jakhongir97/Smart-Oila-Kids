import CoreLocation
import Foundation

extension GeoBackgroundService {
    func updateDebug(
        status: GeoConnectionStatus? = nil,
        endpoint: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil,
        lastLatitude: Double? = nil,
        lastLongitude: Double? = nil,
        lastLocationAt: Date? = nil,
        lastHorizontalAccuracy: Double? = nil,
        recordEvent: Bool = true
    ) {
        updateDebugSnapshot(
            status: status?.rawValue,
            endpoint: endpoint,
            lastPayload: lastPayload,
            lastError: lastError,
            reconnectCount: reconnectCount,
            lastLatitude: lastLatitude,
            lastLongitude: lastLongitude,
            lastLocationAt: lastLocationAt,
            lastHorizontalAccuracy: lastHorizontalAccuracy,
            recordEvent: recordEvent
        )
    }

    func updateDebugSnapshot(
        status: String? = nil,
        endpoint: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil,
        lastLatitude: Double? = nil,
        lastLongitude: Double? = nil,
        lastLocationAt: Date? = nil,
        lastHorizontalAccuracy: Double? = nil,
        recordEvent: Bool = true
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            var snapshot = self.debugSnapshot
            if let status {
                snapshot.status = status
            }
            if let endpoint {
                snapshot.endpoint = endpoint
            }
            if let lastPayload {
                snapshot.lastPayload = lastPayload
            }
            if let lastError {
                snapshot.lastError = lastError
            }
            if let reconnectCount {
                snapshot.reconnectCount = reconnectCount
            }
            if let lastLatitude {
                snapshot.lastLatitude = lastLatitude
            }
            if let lastLongitude {
                snapshot.lastLongitude = lastLongitude
            }
            if let lastLocationAt {
                snapshot.lastLocationAt = lastLocationAt
            }
            if let lastHorizontalAccuracy {
                snapshot.lastHorizontalAccuracy = lastHorizontalAccuracy
            }
            self.setDebugSnapshot(snapshot)

            let currentDSN = self.state.currentDSN ?? "-"
            Task { @MainActor in
                RuntimeDiagnosticsCenter.shared.updateGeo(
                    status: snapshot.status,
                    endpoint: snapshot.endpoint,
                    dsn: currentDSN,
                    lastPayload: snapshot.lastPayload,
                    lastError: snapshot.lastError,
                    reconnectCount: snapshot.reconnectCount,
                    lastLatitude: snapshot.lastLatitude,
                    lastLongitude: snapshot.lastLongitude,
                    lastLocationAt: snapshot.lastLocationAt,
                    lastHorizontalAccuracy: snapshot.lastHorizontalAccuracy,
                    recordEvent: recordEvent
                )
            }
        }
    }

    func updateLocationDebugSnapshot(for location: CLLocation, recordEvent: Bool = false) {
        updateDebugSnapshot(
            lastLatitude: location.coordinate.latitude,
            lastLongitude: location.coordinate.longitude,
            lastLocationAt: location.timestamp,
            lastHorizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            recordEvent: recordEvent
        )
    }

    func debugLog(_ message: String) {
#if DEBUG
        print("[GeoBackgroundService] \(message)")
#endif
    }
}

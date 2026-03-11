import Foundation

extension GeoBackgroundService {
    func updateDebug(
        status: GeoConnectionStatus? = nil,
        endpoint: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        updateDebugSnapshot(
            status: status?.rawValue,
            endpoint: endpoint,
            lastPayload: lastPayload,
            lastError: lastError,
            reconnectCount: reconnectCount
        )
    }

    func updateDebugSnapshot(
        status: String? = nil,
        endpoint: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
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
            self.setDebugSnapshot(snapshot)

            let currentDSN = self.state.currentDSN ?? "-"
            Task { @MainActor in
                RuntimeDiagnosticsCenter.shared.updateGeo(
                    status: snapshot.status,
                    endpoint: snapshot.endpoint,
                    dsn: currentDSN,
                    lastPayload: snapshot.lastPayload,
                    lastError: snapshot.lastError,
                    reconnectCount: snapshot.reconnectCount
                )
            }
        }
    }

    func debugLog(_ message: String) {
#if DEBUG
        print("[GeoBackgroundService] \(message)")
#endif
    }
}

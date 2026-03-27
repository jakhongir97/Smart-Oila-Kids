import CoreLocation
import Foundation

extension GeoBackgroundService {
    func locationAuthorizationFailureReason(for authorizationStatus: CLAuthorizationStatus) -> String? {
        switch authorizationStatus {
        case .authorizedAlways:
            return nil
        case .authorizedWhenInUse:
            return "Location Always authorization is required for background tracking"
        case .notDetermined:
            return "Location permission has not been granted yet"
        case .denied, .restricted:
            return "Location access is unavailable for background tracking"
        @unknown default:
            return "Location authorization status is unknown"
        }
    }

    func shouldStartLocationUpdates(for authorizationStatus: CLAuthorizationStatus) -> Bool {
        switch authorizationStatus {
        case .authorizedAlways:
            return true
        case .authorizedWhenInUse, .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    @discardableResult
    func restart(using dsn: String? = nil) -> Bool {
        let normalizedDSN = dsn?.trimmedNonEmpty ?? state.currentDSN?.trimmedNonEmpty
        guard let normalizedDSN else { return false }

        stop()
        start(dsn: normalizedDSN)
        return true
    }

    func start(dsn: String) {
        guard let normalizedDSN = dsn.trimmedNonEmpty else {
            stop()
            return
        }

        if state.isRunning,
           let currentDSN = state.currentDSN,
           currentDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame {
            return
        }

        stop()

        state.currentDSN = normalizedDSN
        let restoredCount = pendingPayloadQueue.restore(for: normalizedDSN)
        if restoredCount > 0 {
            debugLog("Restored queued payloads: \(restoredCount)")
        }

        state.isRunning = true
        state.isDisconnectRequested = false
        state.currentBaseIndex = 0
        state.reconnectAttemptCount = 0

        debugLog("start(dsn: \(normalizedDSN))")
        updateDebug(status: .starting, endpoint: "-", lastError: "-")

        startLocationUpdatesIfAuthorized()
        timers.start()
        connectUsingCurrentBase()
    }

    func stop(shouldUpdateDebug: Bool = true) {
        if let dsn = state.currentDSN {
            pendingPayloadQueue.persist(for: dsn)
        }

        state.isRunning = false
        state.isDisconnectRequested = true
        state.currentDSN = nil

        debugLog("stop()")

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        locationManager.stopUpdatingLocation()
        timers.stop()
        webSocketClient.disconnect()

        if shouldUpdateDebug {
            updateDebug(status: .stopped, endpoint: "-", lastError: "-")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startLocationUpdatesIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state.isRunning, let location = locations.last else { return }

        if let previous = state.lastKnownLocation {
            let moved = location.distance(from: previous)
            guard moved >= configuration.minDistance else { return }
        }

        state.lastKnownLocation = location
        sendLocation(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep service alive; temporary location failures are expected on iOS.
    }

    @objc
    func handleDeviceStateChange() {
        sendSystemInfoIfChanged()
    }

    func sendLastKnownLocation() {
        guard let location = state.lastKnownLocation else { return }
        sendLocation(location)
    }

    func handlePathUpdate() {
        guard state.isRunning else { return }

        sendSystemInfoIfChanged()

        guard pathMonitor.currentPath.status == .satisfied else { return }

        let needsReconnect = !webSocketClient.isConnected || shouldReconnectBasedOnDebugStatus
        guard needsReconnect else { return }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        state.currentBaseIndex = 0
        connectUsingCurrentBase()
    }

    var shouldReconnectBasedOnDebugStatus: Bool {
        guard let status = GeoConnectionStatus(rawValue: debugStatus) else {
            return false
        }

        switch status {
        case .failed, .queued, .reconnecting:
            return true
        default:
            return false
        }
    }

    func startLocationUpdatesIfAuthorized() {
        guard state.isRunning else { return }

        let authorizationStatus = locationManager.authorizationStatus

        if let failureReason = locationAuthorizationFailureReason(for: authorizationStatus) {
            updateDebugSnapshot(
                status: "not_authorized",
                lastError: failureReason
            )
        } else {
            updateDebugSnapshot(lastError: "-")
        }

        switch authorizationStatus {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse, .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }
}
